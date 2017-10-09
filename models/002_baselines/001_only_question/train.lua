require 'torch'
require 'nn'
require 'nngraph'
require 'math'

-- exotic things
require 'image'

-- local imports
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
cmd:text('Train an Only Question Baseline Model')
cmd:text()
cmd:text('Options')

------------------------ Data input settings ------------------------
-- Loader input
cmd:option('-clip_info_file','data/clip_info.json','path to precomputed skip-thoughts vector for all captions')
cmd:option('-qa_label_file','data/qa_labels.h5','path to precomputed skip-thoughts vector for all captions')

-- Sentence embedding input
cmd:option('-uni_gru_path','data/pretrained_models/skipthought/uni_gru_params.t7','path to skip-thoughts vector GRU model')
cmd:option('-uni_gru_word2vec_path','data/pretrained_models/skipthought/videoqa_uni_gru_word2vec.t7','path to skip-thoughts vector word embedding model')

-- Model Finetuning options
cmd:option('-start_from', '', 'path to a model checkpoint to initialize model weights from. Empty = don\'t')
cmd:option('-ft_continue', 1,'whether maintain the epoch and iteration of checkpoint or not')

-- Model parameter or input dimension settings
cmd:option('-question_feat_dim',2400,'dimension of the skipthought feature from caption')
cmd:option('-clip_feat_dim',512,'dimension of the cnn feature from image')
cmd:option('-emb_dim',512,'dimension of embedding space of img and cap for attention')
cmd:option('-drop_prob', 0.5, 'strength of dropout in the Language Model RNN')

-- Optimization: General
cmd:option('-max_epoch', 100, 'max number of iterations to run for (-1 = run forever)')
cmd:option('-batch_size',1,'what is the batch size in number of images per batch? (there will be x seq_per_img sentences)')
cmd:option('-grad_clip',0.1,'clip gradients at this value (note should be lower than usual 5 because we normalize grads by both batch and seq_length)')
cmd:option('-optim_alpha',0.9,'alpha for adam')
cmd:option('-optim_beta',0.999,'beta used for adam')
cmd:option('-optim_epsilon',1e-8,'epsilon that goes into denominator for smoothing')

-- Optimization: for the learning rate
cmd:option('-learning_rate',1e-4,'learning rate')
cmd:option('-learning_rate_decay_start', 1, 'at what iteration to start decaying learning rate? (-1 = dont)')
cmd:option('-learning_rate_decay_every', 3, 'every how many iterations thereafter to drop LR by half?')
cmd:option('-lr_decay_rate', 0.8, 'every how many iterations thereafter to drop LR by half?')

-- Evaluation/Checkpointing
cmd:option('-val_images_use', 500, 'how many images to use when periodically evaluating the validation loss? (-1 = all)')
cmd:option('-checkpoint_path', './model/', 'folder to save checkpoints into (empty = this folder)')
cmd:option('-losses_log_every', 10, 'How often do we snapshot losses, for inclusion in the progress dump? (0 = disable)')

-- misc
cmd:option('-img_root', 'data/mario_resized_frames/')
cmd:option('-backend', 'nn', 'nn|cudnn')
cmd:option('-debug', false, 'Debug mode?')
cmd:option('-every_vis', 300, 'visualization of attention')
cmd:option('-id', '', 'an id identifying this run/job. used in cross-val and appended when writing progress files')
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
                           fix_num_frame=true, data_path=opt.img_root}

-------------------------------------------------------------------------------
-- Initialize the networks
-------------------------------------------------------------------------------
local net = {}
local kk = 10
local iter = 1
local epoch = 1
local train_acc = 0
local timer = torch.Timer()

if string.len(opt.start_from) > 0 then  -- finetuning the model
   -- load net from file
   print('initializing weights from ' .. opt.start_from)
   local loaded_checkpoint = torch.load(opt.start_from)

   -- continue learning from previous model's iteration and epoch
   if opt.ft_continue > 0 then
      print('Fintuning continue from before model, meaning epoch and iteration is maintained')
      epoch = loaded_checkpoint.epoch +1
      local every_epoch = math.ceil(loader:getNumTrainData() / opt.batch_size)
      if opt.batch_size ~= loaded_checkpoint.opt.batch_size then
         iter = math.ceil(loader:getNumTrainData() / opt.batch_size) * (epoch-1) + 1
      else
         iter = loaded_checkpoint.iter + 1
      end
   end

   net = loaded_checkpoint.net
   net.crit = nn.CrossEntropyCriterion() -- not in checkpoints, create manually

   ----------------------------------------------------------------------------
   -- Unsanitize gradient for each model
   ----------------------------------------------------------------------------

   -- load question encoder
   local qe_modules = net.question_encoder:getModulesList()
   for k,v in pairs(qe_modules) do net_utils.unsanitize_gradients(v) end

   -- load classification and criterion layer
   net_utils.unsanitize_gradients(net.classify)

   ----------------------------- end if ----------------------------------
else -- create net from scratch

   -- attatch question encoder
   print('Question encoder is initialized from skip-thought vector model')
   local uparams = torch.load(opt.uni_gru_path)
   local utables = torch.load(opt.uni_gru_word2vec_path)
   local qeOpt = {}
   qeOpt.backend = 'nn'   -- cudnn may not work
   qeOpt.vocab_size = loader:getVocabSize()
   qeOpt.seq_length = loader:getQstLength()
   print('Option of Question encoder is as follows :')
   print(qeOpt)
   net.question_encoder = nn.sentenceEncoder(uparams, utables, qeOpt)

   -- attatch classification layer
   net.classify = nn.Sequential()
   net.classify:add( nn.Linear(opt.question_feat_dim, opt.clip_feat_dim) )
   net.classify:add( nn.ReLU() )
   net.classify:add( nn.Linear(opt.clip_feat_dim, loader.num_answer) )

   -- attatch criterion layer
   net.crit = nn.CrossEntropyCriterion()
end
--------------------------------------------------------------------------------------------------
-- Should keep following order
-- 1. ship to GPU       -> memory reallocation
-- 2. getParameters()   -> memory reallocation, so should be done before next two steps.
-- 3. sanitizing network to save with lower memory
-- 4. create clones

-- ship everything to GPU, maybe
if opt.gpuid >= 0 then
   for k,v in pairs(net) do v:cuda() end
end

--------------------------------------------------------------------------------------------------
-- flatten and prepare all model parameters to a single vector.
local qe_params, grad_qe_params = net.question_encoder:getParameters()
local cls_params, grad_cls_params = net.classify:getParameters()

print('\n============================================================')
print('total number of parameters in QE     : ', qe_params:nElement())
print('total number of parameters in CLS    : ', cls_params:nElement())

--------------------------------------------------------------------------------------------------
-- construct thin module clones that share parameters with the actual
-- modules. These thin module will have no intermediates and will be used
-- for checkpointing to write significantly smaller checkpoint files

-- sanitize question embedding layer
local thin_qe = net.question_encoder:clone()
thin_qe.core:share(net.question_encoder.core, 'weight', 'bias')
thin_qe.lookup_table:share(net.question_encoder.lookup_table, 'weight', 'bias')
local qe_modules = thin_qe:getModulesList()
for k,v in pairs(qe_modules) do net_utils.sanitize_gradients(v) end

-- sanitize classifying layer
local thin_cls = net.classify:clone('weight', 'bias')
net_utils.sanitize_gradients(thin_cls)
--------------------------------------------------------------------------------------------------

-- create clones and ensure parameter sharing. we have to do this
-- all the way here at the end because calls such as :cuda() and
-- :getParameters() reshuffle memory around.
net.question_encoder:createClones()

--------------------------------------------------------------------------------------------------
collectgarbage()

-------------------------------------------------------------------------------
-- Validation evaluation
-------------------------------------------------------------------------------
local function eval_split(split, evalopt)
   local verbose = utils.getopt(evalopt, 'verbose', true)
   local val_images_use = utils.getopt(evalopt, 'val_images_use', -1)
   
   net.question_encoder:evaluate(); 
   net.classify:evaluate()
   
   loader:resetIterator(split) -- rewind iteator back to first datapoint in the split
   local n = 0
   local loss_sum = 0
   local loss_evals = 0
   local test_acc = 0
   local prediction = {}
   
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
      local pred = net.classify:forward(qst_feat)
      local loss = net.crit:forward(pred, data.answers)
   
      loss_sum = loss_sum + loss
      loss_evals = loss_evals + 1
      local max_score, ans = torch.max(pred:squeeze(), 1)
      test_acc = test_acc + torch.eq(ans:cuda(), data.answers):sum()
   
      -- save the prediction results
      table.insert(prediction, ans:squeeze())
   
      -----------------------------------------------------------------------------
      -- if we wrapped around the split or used up val imgs budget then bail
      local ix0 = data.bounds.it_pos_now
      local ix1 = math.min(data.bounds.it_max, val_images_use)
      if verbose then
         local qst_label = torch.squeeze( data.questions[{ {},1 }] )
         local qst = ''
         for i=1, qst_label:size(1) do
            if qst_label[i] ~= 0 then
               qst = qst .. loader:getVocabQuestion()[ tostring(qst_label[i]) ] .. ' '
            end
         end
         print(string.format('question    : (%s)', qst))
         print(string.format('pred answer : (%s)', loader:getVocabAnswer()[ tostring(ans[1]-1)]))
         print(string.format('gt answer   : (%s)', loader:getVocabAnswer()[ tostring(data.answers[1]-1)]))
         print(string.format('evaluating validation performance... %d/%d (%f)', ix0-1, ix1, loss))
      end
   
      if loss_evals % 10 == 0 then collectgarbage() end
      if data.bounds.wrapped then break end -- the split ran out of data, lets break out
      if val_images_use >= 0 and n >= val_images_use then break end -- we've used enough images
      print('-----------------------------------------------------------------------------------')
   end
   
   test_acc = test_acc / n
   
   return loss_sum / loss_evals, test_acc, prediction
end

-------------------------------------------------------------------------------
-- Loss function
-------------------------------------------------------------------------------
local function lossFun()
   net.question_encoder:training(); 
   net.classify:training()
   grad_qe_params:zero(); 
   grad_cls_params:zero()

   local batch_loss = 0

   -----------------------------------------------------------------------------
   -- Load minibatch data
   -----------------------------------------------------------------------------
   local st = timer:time().real
   local data = loader:getBatch{batch_size = opt.batch_size, split = 'train'}
   local data_load_time = timer:time().real - st


   local forward_time, backward_time = 0, 0
   -- Here, gradients are accumulated
   for bi=1,opt.batch_size do
      -----------------------------------------------------------------------------
      -- Forward pass
      -----------------------------------------------------------------------------
      st = timer:time().real
      local qst_feat  = net.question_encoder:forward({data.questions[{ {},{bi} }], data.question_length[{{bi}}]})
      local pred = net.classify:forward(qst_feat)
      local loss = net.crit:forward(pred, data.answers[{ {bi} }])
      batch_loss = batch_loss + loss
      forward_time = forward_time + timer:time().real - st

      local max_score, pred_ans = torch.max(pred:squeeze(), 1)
      train_acc = train_acc + torch.eq(pred_ans:cuda(), data.answers[{ {bi} }]):sum()

      if iter%100 == 0 then
         local qst_label = torch.squeeze( data.questions[{ {},bi }] )
         local qst = ''
         for i=1, qst_label:size(1) do
            if qst_label[i] ~= 0 then
               qst = qst .. loader:getVocabQuestion()[ tostring(qst_label[i]) ] .. ' '
            end
         end
         print(string.format('==>question    : (%s)', qst))
         print(string.format('==>pred answer : (%s)', loader:getVocabAnswer()[ tostring(pred_ans[1]-1)]))
         print(string.format('==>gt answer   : (%s)', loader:getVocabAnswer()[ tostring(data.answers[bi]-1)]))
      end

      -----------------------------------------------------------------------------
      -- Backward pass
      -----------------------------------------------------------------------------
      st = timer:time().real
      local dpred = net.crit:backward(pred, data.answers[{ {bi} }])
      local dqst_feat = net.classify:backward(qst_feat, dpred)
      local dqst = net.question_encoder:backward({data.questions[{ {},{bi} }], data.question_length[{ {bi} }]}, dqst_feat)
      backward_time = backward_time + timer:time().real - st

      if loss >= 10 then print(string.format('Oops!! Loss is bigger than 10 (%.3f) (%s)',loss,data.clips[bi]['video_path'])) end
   end

   -- divide gradient by batch size
   grad_cls_params:mul(1/opt.batch_size)
   grad_qe_params:mul(1/opt.batch_size)

   -- clip gradients
   grad_cls_params:clamp(-opt.grad_clip, opt.grad_clip)
   grad_qe_params:clamp(-opt.grad_clip, opt.grad_clip)


   -----------------------------------------------------------------------------
   local all_time = data_load_time + forward_time + backward_time
   print(string.format('Elapsed time : data_load (%.4fs) | forward (%.4fs) | backward (%.4fs) | all (%.4fs)', data_load_time, forward_time, backward_time, all_time))

   -- and lets get out!
   local losses = { total_loss = batch_loss/opt.batch_size}
   return losses
end

-------------------------------------------------------------------------------
-- Main loop
-------------------------------------------------------------------------------
local loss0
local best_score
local qe_optim_state, c3d_optim_state, cls_optim_state = {}, {}, {}
local loss_history = {}
local predictions_history = {}
local every_epoch = math.ceil(loader:getNumTrainData() / opt.batch_size)

print('The number of iterations per epoch : ', every_epoch)
while true do
   print('\n--------------------------------------------------------------------------------')
   print(string.format('epoch %d iter %d', epoch, iter))

   -- eval loss/gradient
   local losses = lossFun()
   if iter % opt.losses_log_every == 0 then table.insert(loss_history, losses.total_loss) end

   if iter % 10 == 0 then
      local qe_param_norm = qe_params:norm()
      local qe_grad_norm = grad_qe_params:norm()
      local cls_param_norm = cls_params:norm()
      local cls_grad_norm = grad_cls_params:norm()

      print(string.format('QE param  : %f', qe_param_norm))
      print(string.format('QE grad   : %.7f', qe_grad_norm))
      print(string.format('CLS param : %.7f', cls_param_norm))
      print(string.format('CLS grad  : %.7f', cls_grad_norm))

   end

   -----------------------------------------------------------------------------
   -- save checkpoint at every epoch (or on final iteration)
   if  iter % every_epoch == 0 or iter == opt.max_epoch*every_epoch then
      -- evaluate the validation performance
      local val_loss, val_acc, val_prediction = eval_split('val', {val_images_use = opt.val_images_use})
      table.insert(predictions_history, val_prediction)
      print('==========================================================')
      print('=====> validation loss: ', val_loss)
      print('=====> validation accuracy: ', val_acc)
      print('=====> train      accuracy: ', train_acc/loader:getNumTrainData())
      print('==========================================================')

      -- write a (thin) json report
      local checkpoint_path = path.join(opt.checkpoint_path, 'model_id' .. tostring(epoch))
      local checkpoint = {}
      checkpoint.opt = opt
      checkpoint.iter = iter
      checkpoint.epoch = epoch
      checkpoint.loss_history = loss_history
      checkpoint.prediction_history = predictions_history

      utils.write_json(checkpoint_path .. '.json', checkpoint)
      print('wrote json checkpoint to ' .. checkpoint_path .. '.json')

      -- Save the current network
      local save_net = {}
      save_net.question_encoder = thin_qe
      save_net.classify         = thin_cls
      checkpoint.net = save_net
      -- also include the vocabulary mapping so that we can use the checkpoint 
      -- alone to run on arbitrary images without the data loader
      checkpoint.ix_to_word = loader:getVocabQuestion()
      checkpoint.ix_to_ans = loader:getVocabAnswer()
      torch.save(checkpoint_path .. '.t7', checkpoint)
      print('wrote checkpoint to ' .. checkpoint_path .. '.t7')

      -- write the full model checkpoint as well if we did better than ever
      local current_score = -val_loss
      if best_score == nil or current_score > best_score then
         best_score = current_score
         if iter > 0 then -- dont save on very first iteration
            torch.save(checkpoint_path .. 'best_score.t7', checkpoint)
            print('wrote best score checkpoint to ' .. checkpoint_path .. 'best_score.t7')
         end
      end
      if iter ~= 0 then epoch = epoch + 1 end

      train_acc = 0
   end
   -----------------------------------------------------------------------------

   -- decay the learning rate for both LM and CNN
   local learning_rate = opt.learning_rate
   local cnn_learning_rate = opt.cnn_learning_rate
   if epoch > opt.learning_rate_decay_start and opt.learning_rate_decay_start >= 0 then
      local frac = (epoch - opt.learning_rate_decay_start) / opt.learning_rate_decay_every
      local decay_factor = math.pow(opt.lr_decay_rate, frac)
      learning_rate = learning_rate * decay_factor -- set the decayed rate
   end
   print(string.format('Loss : %.2f\t | lr : %.5f\t', losses.total_loss, learning_rate))

   -- perform a parameter update
   adam(cls_params, grad_cls_params, learning_rate, opt.optim_alpha, opt.optim_beta, opt.optim_epsilon, cls_optim_state)
   adam(qe_params, grad_qe_params, learning_rate, opt.optim_alpha, opt.optim_beta, opt.optim_epsilon, qe_optim_state)

   -- stopping criterions
   iter = iter + 1
   if iter % 10 == 0 then collectgarbage() end -- good idea to do this once in a while, i think
   if loss0 == nil then loss0 = losses.total_loss end
   if losses.total_loss > loss0 * 20 then
      print('loss seems to be exploding, quitting.')
   end
   if opt.max_epoch> 0 and epoch >= opt.max_epoch then break end -- stopping criterion
end
