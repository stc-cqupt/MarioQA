require 'torch'
require 'nn'
require 'nngraph'
require 'math'

-- exotic things
require 'loadcaffe'
require 'image'

-- local imports
local ST = require 'layers.spatioTemporalAttention'
require 'layers.sentenceEncoder'
require 'misc.DataLoader'
local utils = require 'misc.utils'
local net_utils = require 'misc.net_utils'
require 'misc.optim_updates'

-------------------------------------------------------------------------------
-- Input arguments and options
-------------------------------------------------------------------------------
cmd = torch.CmdLine()
cmd:text()
cmd:text('Evaluate VideoQA Spatio-Temporal Attention Model')
cmd:text()
cmd:text('Options')

------------------------ Data input settings ------------------------
-- Loader input
cmd:option('-clip_info_file','data/clip_info.json','path to clip information file')
cmd:option('-qa_label_file','data/qa_labels.h5','path to QA labels')
cmd:option('-output_prefix','_eval_out','path to precomputed skip-thoughts vector for all captions')

-- Sentence embedding input
cmd:option('-uni_gru_path','data/pretrained_models/skipthought/uni_gru_params.t7','path to skip-thoughts vector GRU model')
cmd:option('-uni_gru_word2vec_path','data/pretrained_models/skipthought/videoqa_uni_gru_word2vec.t7','path to skip-thoughts vector word embedding model')

-- pretrained CNN model
cmd:option('-cnn_proto','data/pretrained_models/vgg16/vgg_16_layers_deploy.prototxt','path to cnn prototxt')
cmd:option('-cnn_model','data/pretrained_models/vgg16/vgg_16_layers.caffemodel','path to cnn model')

-- Model Finetuning options
cmd:option('-start_from', '', 'path to a model checkpoint to initialize model weights from. Empty = don\'t')

-- Model parameter or input dimension settings
cmd:option('-question_feat_dim',2400,'dimension of the skipthought feature from question')
cmd:option('-clip_feat_dim',512,'dimension of the cnn feature from clip')
cmd:option('-drop_prob', 0.5, 'strength of dropout')

-- Evaluation/Checkpointing
cmd:option('-test_clips_use', -1, 'how many images to use when periodically evaluating the validation loss? (-1 = all)')

-- misc
cmd:option('-img_root', 'data/mario_resized_frames/', 'path to clips which are composed of corresponding frames')
cmd:option('-backend', 'cudnn', 'nn|cudnn')
cmd:option('-debug', false, 'whether use debug mode?')
cmd:option('-seed', 123, 'random number generator seed to use')
cmd:option('-gpuid', 0, 'which gpu to use. -1 = use CPU')

cmd:text()

-------------------------------------------------------------------------------
-- Basic Torch initializations
-------------------------------------------------------------------------------
local opt = cmd:parse(arg)
torch.manualSeed(opt.seed)
torch.setdefaulttensortype('torch.FloatTensor') -- for CPU
print('options are as follows :')
print(opt)

if opt.gpuid >= 0 then
   require 'cutorch'
   require 'cunn'
   if opt.backend == 'cudnn' then require 'cudnn' end
   cutorch.manualSeed(opt.seed)
   cutorch.setDevice(opt.gpuid + 1) -- note +1 because lua is 1-indexed
end

-------------------------------------------------------------------------------
-- Create the Data Loader instance
-------------------------------------------------------------------------------
local loader = DataLoader{clip_info_file=opt.clip_info_file, qa_label_file=opt.qa_label_file,
                           fix_num_frame=false, data_path=opt.img_root}

-------------------------------------------------------------------------------
-- Initialize the networks
-------------------------------------------------------------------------------
local net = {}
local timer = torch.Timer()

if string.len(opt.start_from) > 0 then
   -- load net from file
   print('initializing weights from ' .. opt.start_from)
   local loaded_checkpoint = torch.load(opt.start_from)

   net = loaded_checkpoint.net
   net.crit = nn.CrossEntropyCriterion() -- not in checkpoints, create manually

   ----------------------------------------------------------------------------
   -- Unsanitize gradient for each model
   ----------------------------------------------------------------------------

   -- load question encoder
   local qe_modules = net.question_encoder:get(1):getModulesList()
   for k,v in pairs(qe_modules) do net_utils.unsanitize_gradients(v) end
   net_utils.unsanitize_gradients(net.question_encoder:get(2))
   net.question_encoder:get(1).seq_length = loader:getQstLength()

   -- load C3D image encoder
   net_utils.unsanitize_gradients(net.c3d_net)

   -- load attention models
   net_utils.unsanitize_gradients(net.att)

   -- load classification and criterion layer
   net_utils.unsanitize_gradients(net.classify)

   -- load vocabulary
	loader:setVocabQuestion(loaded_checkpoint.ix_to_word)
	loader:setVocabAnswer(loaded_checkpoint.ix_to_ans)
else
	assert(false, '@@@@@ Trained model should be provided!! @@@@@')
end

--------------------------------------------------------------------------------------------------
-- Should keep following order
-- 1. ship to GPU       -> memory reallocation
-- 4. create clones

-- ship everything to GPU, maybe
if opt.gpuid >= 0 then
   for k,v in pairs(net) do v:cuda() end
end

--------------------------------------------------------------------------------------------------
-- create clones and ensure parameter sharing. we have to do this
-- all the way here at the end because calls such as :cuda() and
-- :getParameters() reshuffle memory around.
net.question_encoder:get(1):createClones()

--------------------------------------------------------------------------------------------------
collectgarbage()

-------------------------------------------------------------------------------
-- Validation evaluation
-------------------------------------------------------------------------------
local function eval_split(split, evalopt)
   local verbose = utils.getopt(evalopt, 'verbose', true)
   local test_clips_use = utils.getopt(evalopt, 'test_clips_use', -1)
   net.question_encoder:evaluate();
   net.c3d_net:evaluate()
   net.att:evaluate()
   net.classify:evaluate()
   
   loader:resetIterator(split) -- rewind iteator back to first datapoint in the split
   local n = 0
   local loss_sum = 0
   local loss_evals = 0
   local test_acc = 0
   local vocab_qst = loader:getVocabQuestion()
   local vocab_ans = loader:getVocabAnswer()
   local prediction = {}
   local data_info = {}
   
   print('\n--------------------- Evaluation for test split -----------------------')
   while true do
   
      -----------------------------------------------------------------------------
      -- Load minibatch data 
      -----------------------------------------------------------------------------
      local data = loader:getBatch{batch_size = 1, split = split}
      n = n + data.answers:size(1)
   
      -----------------------------------------------------------------------------
      -- Forward network
      -----------------------------------------------------------------------------
      local qst_feat = net.question_encoder:forward({data.questions, data.question_length})
      local clip_feat = net.c3d_net:forward(data.clips[1])
      local cf_size = clip_feat:size()
      local att_feat, alphas = unpack( net.att:forward({clip_feat, qst_feat:repeatTensor(cf_size[2]*cf_size[3]*cf_size[4], 1)}) )
      local pred = net.classify:forward({att_feat,qst_feat})
      local loss = net.crit:forward(pred, data.answers[{ {1} }])
   
      loss_sum = loss_sum + loss
      loss_evals = loss_evals + 1
      local max_score, ans = torch.max(pred, 2)
      test_acc = test_acc + torch.eq(ans[1]:cuda(), data.answers[{{1}}]):sum()
   
      -- save the prediction results
      table.insert(prediction, net_utils.decode_answer(vocab_ans, ans[1][1]) )
		table.insert(data_info, data.infos)
		torch.save( string.format('att_map_test/att_map_%d.t7', n), alphas:float() )
   
      -----------------------------------------------------------------------------
      -- if we wrapped around the split or used up val imgs budget then bail
      local ix0 = data.bounds.it_pos_now
      local ix1 = math.min(data.bounds.it_max, test_clips_use)
      if verbose then
         local qst_label = torch.squeeze( data.questions[{ {},1 }] )
         local qst = ''
         for i=1, qst_label:size(1) do
            if qst_label[i] ~= 0 then
               qst = qst .. vocab_qst[ tostring(qst_label[i]) ] .. ' '
            end
         end
         print(string.format('question    : (%s)', qst))
         print(string.format('pred answer : (%s)', vocab_ans[ tostring(ans[1][1]-1)]))
         print(string.format('gt answer   : (%s)', vocab_ans[ tostring(data.answers[1]-1)]))
         print(string.format('evaluating validation performance... %d/%d (%f)', ix0-1, ix1, loss))
      end
   
      if loss_evals % 10 == 0 then collectgarbage() end
      if data.bounds.wrapped then break end -- the split ran out of data, lets break out
      if test_clips_use >= 0 and n >= test_clips_use then break end -- we've used enough images
      print('-----------------------------------------------------------------------------------')
   end
   
   test_acc = test_acc / n
   
   return loss_sum / loss_evals, test_acc, prediction, data_info
end

-------------------------------------------------------------------------------
-- Main loop
-------------------------------------------------------------------------------
-- evaluate the validation performance
local val_loss, val_acc, val_prediction, val_info = eval_split('test', {test_clips_use = opt.test_clips_use})
print('==========================================================')
print('=====> loss: ', val_loss)
print('=====> accuracy: ', val_acc)
print('==========================================================')

-- write a (thin) json report
local evaluation_output_path = opt.start_from:sub(1,-4) .. opt.output_prefix
local evaluation_output = {}
evaluation_output.opt = opt
evaluation_output.loss = val_loss
evaluation_output.prediction = val_prediction
evaluation_output.clip_info = val_info

utils.write_json(evaluation_output_path .. '.json', evaluation_output)
print('wrote json evaluation_output to ' .. evaluation_output_path .. '.json')
