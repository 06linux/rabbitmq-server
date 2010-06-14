%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2010 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2010 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2010 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_variable_queue).

-export([init/3, terminate/1, publish/2, publish_delivered/3,
         set_ram_duration_target/2, ram_duration/1, fetch/2, ack/2, len/1,
         is_empty/1, purge/1, delete_and_terminate/1, requeue/2, tx_publish/3,
         tx_ack/3, tx_rollback/2, tx_commit/3, needs_sync/1, sync/1,
         handle_pre_hibernate/1, status/1]).

-export([start/1]).

%%----------------------------------------------------------------------------
%% Definitions:

%% alpha: this is a message where both the message itself, and its
%%        position within the queue are held in RAM
%%
%% beta: this is a message where the message itself is only held on
%%        disk, but its position within the queue is held in RAM.
%%
%% gamma: this is a message where the message itself is only held on
%%        disk, but its position is both in RAM and on disk.
%%
%% delta: this is a collection of messages, represented by a single
%%        term, where the messages and their position are only held on
%%        disk.
%%
%% Note that for persistent messages, the message and its position
%% within the queue are always held on disk, *in addition* to being in
%% one of the above classifications.
%%
%% Also note that within this code, the term gamma never
%% appears. Instead, gammas are defined by betas who have had their
%% queue position recorded on disk.
%%
%% In general, messages move q1 -> q2 -> delta -> q3 -> q4, though
%% many of these steps are frequently skipped. q1 and q4 only hold
%% alphas, q2 and q3 hold both betas and gammas (as queues of queues,
%% using the bpqueue module where the block prefix determines whether
%% they're betas or gammas). When a message arrives, its
%% classification is determined. It is then added to the rightmost
%% appropriate queue.
%%
%% If a new message is determined to be a beta or gamma, q1 is
%% empty. If a new message is determined to be a delta, q1 and q2 are
%% empty (and actually q4 too).
%%
%% When removing messages from a queue, if q4 is empty then q3 is read
%% directly. If q3 becomes empty then the next segment's worth of
%% messages from delta are read into q3, reducing the size of
%% delta. If the queue is non empty, either q4 or q3 contain
%% entries. It is never permitted for delta to hold all the messages
%% in the queue.
%%
%% The duration indicated to us by the memory_monitor is used to
%% calculate, given our current ingress and egress rates, how many
%% messages we should hold in RAM. When we need to push alphas to
%% betas or betas to gammas, we favour writing out messages that are
%% further from the head of the queue. This minimises writes to disk,
%% as the messages closer to the tail of the queue stay in the queue
%% for longer, thus do not need to be replaced as quickly by sending
%% other messages to disk.
%%
%% Whilst messages are pushed to disk and forgotten from RAM as soon
%% as requested by a new setting of the queue RAM duration, the
%% inverse is not true: we only load messages back into RAM as
%% demanded as the queue is read from. Thus only publishes to the
%% queue will take up available spare capacity.
%%
%% If a queue is full of transient messages, then the transition from
%% betas to deltas will be potentially very expensive as millions of
%% entries must be written to disk by the queue_index module. This can
%% badly stall the queue. In order to avoid this, the proportion of
%% gammas / (betas+gammas) must not be lower than (betas+gammas) /
%% (alphas+betas+gammas). Thus as the queue grows, and the proportion
%% of alphas shrink, the proportion of gammas will grow, thus at the
%% point at which betas and gammas must be converted to deltas, there
%% should be very few betas remaining, thus the transition is fast (no
%% work needs to be done for the gamma -> delta transition).
%%
%% The conversion of betas to gammas is done on publish, in batches of
%% exactly ?RAM_INDEX_BATCH_SIZE. This value should not be too small,
%% otherwise the frequent operations on the queues of q2 and q3 will
%% not be effectively amortised, nor should it be too big, otherwise a
%% publish will take too long as it attempts to do too much work and
%% thus stalls the queue. Therefore, it must be just right. This
%% approach is preferable to doing work on a new queue-duration
%% because converting all the indicated betas to gammas at that point
%% can be far too expensive, thus requiring batching and segmented
%% work anyway, and furthermore, if we're not getting any publishes
%% anyway then the queue is either being drained or has no
%% consumers. In the latter case, an expensive beta to delta
%% transition doesn't matter, and in the former case the queue's
%% shrinking length makes it unlikely (though not impossible) that the
%% duration will become 0.
%%
%% In the queue we only keep track of messages that are pending
%% delivery. This is fine for queue purging, but can be expensive for
%% queue deletion: for queue deletion we must scan all the way through
%% all remaining segments in the queue index (we start by doing a
%% purge) and delete messages from the msg_store that we find in the
%% queue index.
%%
%% Notes on Clean Shutdown
%% (This documents behaviour in variable_queue, queue_index and
%% msg_store.)
%%
%% In order to try to achieve as fast a start-up as possible, if a
%% clean shutdown occurs, we try to save out state to disk to reduce
%% work on startup. In the msg_store this takes the form of the
%% index_module's state, plus the file_summary ets table, and client
%% refs. In the VQ, this takes the form of the count of persistent
%% messages in the queue and references into the msg_stores. The
%% queue_index adds to these terms the details of its segments and
%% stores the terms in the queue directory.
%%
%% The references to the msg_stores are there so that the msg_store
%% knows to only trust its saved state if all of the queues it was
%% previously talking to come up cleanly. Likewise, the queues
%% themselves (esp queue_index) skips work in init if all the queues
%% and msg_store were shutdown cleanly. This gives both good speed
%% improvements and also robustness so that if anything possibly went
%% wrong in shutdown (or there was subsequent manual tampering), all
%% messages and queues that can be recovered are recovered, safely.
%%
%% To delete transient messages lazily, the variable_queue, on
%% startup, stores the next_seq_id reported by the queue_index as the
%% transient_threshold. From that point on, whenever it's reading a
%% message off disk via the queue_index, if the seq_id is below this
%% threshold and the message is transient then it drops the
%% message. This avoids the expensive operation of scanning the entire
%% queue on startup in order to delete transient messages that were
%% only pushed to disk to save memory.
%%
%%----------------------------------------------------------------------------

-behaviour(rabbit_backing_queue).

-record(vqstate,
        { q1,
          q2,
          delta,
          q3,
          q4,
          next_seq_id,
          pending_ack,
          index_state,
          msg_store_clients,
          on_sync,
          durable,
          transient_threshold,

          len,
          persistent_count,

          duration_target,
          target_ram_msg_count,
          ram_msg_count,
          ram_msg_count_prev,
          ram_index_count,
          out_counter,
          in_counter,
          egress_rate,
          avg_egress_rate,
          ingress_rate,
          avg_ingress_rate,
          rate_timestamp
         }).

-record(msg_status,
        { seq_id,
          guid,
          msg,
          is_persistent,
          is_delivered,
          msg_on_disk,
          index_on_disk
         }).

-record(delta,
        { start_seq_id, %% start_seq_id is inclusive
          count,
          end_seq_id    %% end_seq_id is exclusive
         }).

-record(tx, { pending_messages, pending_acks }).

%% When we discover, on publish, that we should write some indices to
%% disk for some betas, the RAM_INDEX_BATCH_SIZE sets the number of
%% betas that we must be due to write indices for before we do any
%% work at all. This is both a minimum and a maximum - we don't write
%% fewer than RAM_INDEX_BATCH_SIZE indices out in one go, and we don't
%% write more - we can always come back on the next publish to do
%% more.
-define(RAM_INDEX_BATCH_SIZE, 64).
-define(PERSISTENT_MSG_STORE, msg_store_persistent).
-define(TRANSIENT_MSG_STORE,  msg_store_transient).

-include("rabbit.hrl").

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(bpqueue() :: any()).
-type(seq_id()  :: non_neg_integer()).
-type(ack()     :: seq_id() | 'blank_ack').

-type(delta() :: #delta { start_seq_id :: non_neg_integer(),
                          count        :: non_neg_integer (),
                          end_seq_id   :: non_neg_integer() }).

-type(state() :: #vqstate {
             q1                   :: queue(),
             q2                   :: bpqueue(),
             delta                :: delta(),
             q3                   :: bpqueue(),
             q4                   :: queue(),
             next_seq_id          :: seq_id(),
             pending_ack          :: dict(),
             index_state          :: any(),
             msg_store_clients    :: 'undefined' | {{any(), binary()},
                                                    {any(), binary()}},
             on_sync              :: {[[ack()]], [[guid()]],
                                      [fun (() -> any())]},
             durable              :: boolean(),

             len                  :: non_neg_integer(),
             persistent_count     :: non_neg_integer(),

             transient_threshold  :: non_neg_integer(),
             duration_target      :: non_neg_integer(),
             target_ram_msg_count :: non_neg_integer(),
             ram_msg_count        :: non_neg_integer(),
             ram_msg_count_prev   :: non_neg_integer(),
             ram_index_count      :: non_neg_integer(),
             out_counter          :: non_neg_integer(),
             in_counter           :: non_neg_integer(),
             egress_rate          :: {{integer(), integer(), integer()},
                                      non_neg_integer()},
             avg_egress_rate      :: float(),
             ingress_rate         :: {{integer(), integer(), integer()},
                                      non_neg_integer()},
             avg_ingress_rate     :: float(),
             rate_timestamp       :: {integer(), integer(), integer()}
            }).

-include("rabbit_backing_queue_spec.hrl").

-endif.

-define(BLANK_DELTA, #delta { start_seq_id = undefined,
                              count        = 0,
                              end_seq_id   = undefined }).
-define(BLANK_DELTA_PATTERN(Z), #delta { start_seq_id = Z,
                                         count        = 0,
                                         end_seq_id   = Z }).

%%----------------------------------------------------------------------------
%% Public API
%%----------------------------------------------------------------------------

start(DurableQueues) ->
    ok = rabbit_msg_store:clean(?TRANSIENT_MSG_STORE, rabbit_mnesia:dir()),
    {AllTerms, StartFunState} = rabbit_queue_index:recover(DurableQueues),
    Refs = [Ref || Terms <- AllTerms,
                   begin
                       Ref = proplists:get_value(persistent_ref, Terms),
                       Ref =/= undefined
                   end],
    ok = rabbit_sup:start_child(?TRANSIENT_MSG_STORE, rabbit_msg_store,
                                [?TRANSIENT_MSG_STORE, rabbit_mnesia:dir(),
                                 undefined,  {fun (ok) -> finished end, ok}]),
    ok = rabbit_sup:start_child(?PERSISTENT_MSG_STORE, rabbit_msg_store,
                                [?PERSISTENT_MSG_STORE, rabbit_mnesia:dir(),
                                 Refs, StartFunState]).

init(QueueName, IsDurable, _Recover) ->
    MsgStoreRecovered =
        rabbit_msg_store:successfully_recovered_state(?PERSISTENT_MSG_STORE),
    ContainsCheckFun =
        fun (Guid) ->
                rabbit_msg_store:contains(?PERSISTENT_MSG_STORE, Guid)
        end,
    {DeltaCount, Terms, IndexState} =
        rabbit_queue_index:init(QueueName, MsgStoreRecovered, ContainsCheckFun),
    {LowSeqId, NextSeqId, IndexState1} = rabbit_queue_index:bounds(IndexState),

    {PRef, TRef, Terms1} =
        case [persistent_ref, transient_ref] -- proplists:get_keys(Terms) of
            [] -> {proplists:get_value(persistent_ref, Terms),
                   proplists:get_value(transient_ref, Terms),
                   Terms};
            _  -> {rabbit_guid:guid(), rabbit_guid:guid(), []}
        end,
    DeltaCount1 = proplists:get_value(persistent_count, Terms1, DeltaCount),
    Delta = case DeltaCount1 == 0 andalso DeltaCount /= undefined of
                true  -> ?BLANK_DELTA;
                false -> #delta { start_seq_id = LowSeqId,
                                  count        = DeltaCount1,
                                  end_seq_id   = NextSeqId }
            end,
    Now = now(),
    PersistentClient =
        case IsDurable of
            true  -> rabbit_msg_store:client_init(?PERSISTENT_MSG_STORE, PRef);
            false -> undefined
        end,
    TransientClient  = rabbit_msg_store:client_init(?TRANSIENT_MSG_STORE, TRef),
    State = #vqstate {
      q1                   = queue:new(),
      q2                   = bpqueue:new(),
      delta                = Delta,
      q3                   = bpqueue:new(),
      q4                   = queue:new(),
      next_seq_id          = NextSeqId,
      pending_ack          = dict:new(),
      index_state          = IndexState1,
      msg_store_clients    = {{PersistentClient, PRef},
                              {TransientClient, TRef}},
      on_sync              = {[], [], []},
      durable              = IsDurable,
      transient_threshold  = NextSeqId,

      len                  = DeltaCount1,
      persistent_count     = DeltaCount1,

      duration_target      = undefined,
      target_ram_msg_count = undefined,
      ram_msg_count        = 0,
      ram_msg_count_prev   = 0,
      ram_index_count      = 0,
      out_counter          = 0,
      in_counter           = 0,
      egress_rate          = {Now, 0},
      avg_egress_rate      = 0,
      ingress_rate         = {Now, DeltaCount1},
      avg_ingress_rate     = 0,
      rate_timestamp       = Now
     },
    maybe_deltas_to_betas(State).

terminate(State) ->
    State1 = #vqstate { persistent_count  = PCount,
                        index_state       = IndexState,
                        msg_store_clients = {{MSCStateP, PRef},
                                             {MSCStateT, TRef}} } =
        remove_pending_ack(true, tx_commit_index(State)),
    case MSCStateP of
        undefined -> ok;
        _         -> rabbit_msg_store:client_terminate(MSCStateP)
    end,
    rabbit_msg_store:client_terminate(MSCStateT),
    Terms = [{persistent_ref, PRef},
             {transient_ref, TRef},
             {persistent_count, PCount}],
    State1 #vqstate { index_state       = rabbit_queue_index:terminate(
                                            Terms, IndexState),
                      msg_store_clients = undefined }.

%% the only difference between purge and delete is that delete also
%% needs to delete everything that's been delivered and not ack'd.
delete_and_terminate(State) ->
    {_PurgeCount, State1} = purge(State),
    State2 = #vqstate { index_state         = IndexState,
                        msg_store_clients   = {{MSCStateP, PRef},
                                               {MSCStateT, TRef}},
                        transient_threshold = TransientThreshold } =
        remove_pending_ack(false, State1),
    %% flushing here is good because it deletes all full segments,
    %% leaving only partial segments around.
    IndexState1 = rabbit_queue_index:flush(IndexState),
    IndexState2 =
        case rabbit_queue_index:bounds(IndexState1) of
            {N, N, IndexState3} ->
                IndexState3;
            {DeltaSeqId, NextSeqId, IndexState3} ->
                delete1(TransientThreshold, NextSeqId, DeltaSeqId, IndexState3)
        end,
    IndexState5 = rabbit_queue_index:delete_and_terminate(IndexState2),
    case MSCStateP of
        undefined -> ok;
        _         -> rabbit_msg_store:delete_client(
                       ?PERSISTENT_MSG_STORE, PRef),
                     rabbit_msg_store:client_terminate(MSCStateP)
    end,
    rabbit_msg_store:delete_client(?TRANSIENT_MSG_STORE, TRef),
    rabbit_msg_store:client_terminate(MSCStateT),
    State2 #vqstate { index_state       = IndexState5,
                      msg_store_clients = undefined }.

purge(State = #vqstate { q4 = Q4, index_state = IndexState, len = Len }) ->
    {Q4Count, IndexState1} =
        remove_queue_entries(fun rabbit_misc:queue_fold/3, Q4, IndexState),
    {Len, State1} =
        purge1(Q4Count, State #vqstate { q4          = queue:new(),
                                         index_state = IndexState1 }),
    {Len, State1 #vqstate { len              = 0,
                            ram_msg_count    = 0,
                            ram_index_count  = 0,
                            persistent_count = 0 }}.

publish(Msg, State) ->
    State1 = limit_ram_index(State),
    {_SeqId, State2} = publish(Msg, false, false, State1),
    State2.

publish_delivered(false, _Msg, State = #vqstate { len = 0 }) ->
    {blank_ack, State};
publish_delivered(true, Msg = #basic_message { is_persistent = IsPersistent },
                  State = #vqstate { len               = 0,
                                     next_seq_id       = SeqId,
                                     out_counter       = OutCount,
                                     in_counter        = InCount,
                                     persistent_count  = PCount,
                                     pending_ack       = PA,
                                     durable           = IsDurable }) ->
    IsPersistent1 = IsDurable andalso IsPersistent,
    MsgStatus = (msg_status(IsPersistent1, SeqId, Msg))
        #msg_status { is_delivered = true },
    {MsgStatus1, State1} = maybe_write_to_disk(false, false, MsgStatus, State),
    PA1 = record_pending_ack(MsgStatus1, PA),
    PCount1 = PCount + one_if(IsPersistent1),
    {SeqId, State1 #vqstate { next_seq_id       = SeqId    + 1,
                              out_counter       = OutCount + 1,
                              in_counter        = InCount  + 1,
                              persistent_count  = PCount1,
                              pending_ack       = PA1 }}.

fetch(AckRequired, State = #vqstate { q4               = Q4,
                                      ram_msg_count    = RamMsgCount,
                                      out_counter      = OutCount,
                                      index_state      = IndexState,
                                      len              = Len,
                                      persistent_count = PCount,
                                      pending_ack      = PA }) ->
    case queue:out(Q4) of
        {empty, _Q4} ->
            case fetch_from_q3_or_delta(State) of
                {empty, _State1} = Result -> Result;
                {loaded, State1}          -> fetch(AckRequired, State1)
            end;
        {{value, MsgStatus = #msg_status {
                   msg = Msg, guid = Guid, seq_id = SeqId,
                   is_persistent = IsPersistent, is_delivered = IsDelivered,
                   msg_on_disk = MsgOnDisk, index_on_disk = IndexOnDisk }},
         Q4a} ->

            %% 1. Mark it delivered if necessary
            IndexState1 = maybe_write_delivered(
                            IndexOnDisk andalso not IsDelivered,
                            SeqId, IndexState),

            %% 2. Remove from msg_store and queue index, if necessary
            MsgStore = find_msg_store(IsPersistent),
            Rem = fun () -> ok = rabbit_msg_store:remove(MsgStore, [Guid]) end,
            Ack = fun () -> rabbit_queue_index:ack([SeqId], IndexState1) end,
            IndexState2 =
                case {MsgOnDisk, IndexOnDisk, AckRequired, IsPersistent} of
                    {true, false, false,     _} -> Rem(), IndexState1;
                    {true,  true, false,     _} -> Rem(), Ack();
                    {true,  true,  true, false} -> Ack();
                    _                           -> IndexState1
                end,

            %% 3. If an ack is required, add something sensible to PA
            {AckTag, PA1} = case AckRequired of
                                true  -> PA2 = record_pending_ack(
                                                 MsgStatus #msg_status {
                                                   is_delivered = true }, PA),
                                         {SeqId, PA2};
                                false -> {blank_ack, PA}
                            end,

            PCount1 = PCount - one_if(IsPersistent andalso not AckRequired),
            Len1 = Len - 1,
            {{Msg, IsDelivered, AckTag, Len1},
             State #vqstate { q4               = Q4a,
                              ram_msg_count    = RamMsgCount - 1,
                              out_counter      = OutCount + 1,
                              index_state      = IndexState2,
                              len              = Len1,
                              persistent_count = PCount1,
                              pending_ack      = PA1 }}
    end.

ack(AckTags, State) ->
    ack(fun (_AckEntry, State1) -> State1 end, AckTags, State).

tx_publish(Txn, Msg = #basic_message { is_persistent = IsPersistent },
           State = #vqstate { durable           = IsDurable,
                              msg_store_clients = MSCState }) ->
    Tx = #tx { pending_messages = Pubs } = lookup_tx(Txn),
    store_tx(Txn, Tx #tx { pending_messages = [Msg | Pubs] }),
    case IsPersistent andalso IsDurable of
        true  -> MsgStatus = msg_status(true, undefined, Msg),
                 {#msg_status { msg_on_disk = true }, MSCState1} =
                     maybe_write_msg_to_disk(false, MsgStatus, MSCState),
                 State #vqstate { msg_store_clients = MSCState1 };
        false -> State
    end.

tx_ack(Txn, AckTags, State) ->
    Tx = #tx { pending_acks = Acks } = lookup_tx(Txn),
    store_tx(Txn, Tx #tx { pending_acks = [AckTags | Acks] }),
    State.

tx_rollback(Txn, State = #vqstate { durable = IsDurable }) ->
    #tx { pending_acks = AckTags, pending_messages = Pubs } = lookup_tx(Txn),
    erase_tx(Txn),
    ok = case IsDurable of
             true  -> rabbit_msg_store:remove(?PERSISTENT_MSG_STORE,
                                              persistent_guids(Pubs));
             false -> ok
         end,
    {lists:flatten(AckTags), State}.

tx_commit(Txn, Fun, State = #vqstate { durable = IsDurable }) ->
    %% If we are a non-durable queue, or we have no persistent pubs,
    %% we can skip the msg_store loop.
    #tx { pending_acks = AckTags, pending_messages = Pubs } = lookup_tx(Txn),
    erase_tx(Txn),
    PubsOrdered = lists:reverse(Pubs),
    AckTags1 = lists:flatten(AckTags),
    PersistentGuids = persistent_guids(PubsOrdered),
    IsTransientPubs = [] == PersistentGuids,
    {AckTags1,
     case (not IsDurable) orelse IsTransientPubs of
         true  -> tx_commit_post_msg_store(
                    IsTransientPubs, PubsOrdered, AckTags1, Fun, State);
         false -> ok = rabbit_msg_store:sync(
                         ?PERSISTENT_MSG_STORE, PersistentGuids,
                         msg_store_callback(PersistentGuids, IsTransientPubs,
                                            PubsOrdered, AckTags1, Fun)),
                  State
     end}.

requeue(AckTags, State) ->
    ack(fun (#msg_status { msg = Msg }, State1) ->
                {_SeqId, State2} = publish(Msg, true, false, State1),
                State2;
            ({IsPersistent, Guid}, State1 = #vqstate {
                                     msg_store_clients = MSCState }) ->
                {{ok, Msg = #basic_message{}}, MSCState1} =
                    read_from_msg_store(MSCState, IsPersistent, Guid),
                {_SeqId, State2} = publish(Msg, true, true,
                                           State1 #vqstate {
                                             msg_store_clients = MSCState1 }),
                State2
        end, AckTags, State).

len(#vqstate { len = Len }) ->
    Len.

is_empty(State) ->
    0 == len(State).

set_ram_duration_target(DurationTarget,
                        State = #vqstate {
                          avg_egress_rate      = AvgEgressRate,
                          avg_ingress_rate     = AvgIngressRate,
                          target_ram_msg_count = TargetRamMsgCount }) ->
    Rate = AvgEgressRate + AvgIngressRate,
    TargetRamMsgCount1 =
        case DurationTarget of
            infinity  -> undefined;
            undefined -> undefined;
            _         -> trunc(DurationTarget * Rate) %% msgs = sec * msgs/sec
        end,
    State1 = State #vqstate { target_ram_msg_count = TargetRamMsgCount1,
                              duration_target      = DurationTarget },
    case TargetRamMsgCount1 == undefined orelse
        TargetRamMsgCount1 >= TargetRamMsgCount of
        true  -> State1;
        false -> reduce_memory_use(State1)
    end.

ram_duration(State = #vqstate { egress_rate        = Egress,
                                ingress_rate       = Ingress,
                                rate_timestamp     = Timestamp,
                                in_counter         = InCount,
                                out_counter        = OutCount,
                                ram_msg_count      = RamMsgCount,
                                duration_target    = DurationTarget,
                                ram_msg_count_prev = RamMsgCountPrev }) ->
    Now = now(),
    {AvgEgressRate,   Egress1} = update_rate(Now, Timestamp, OutCount, Egress),
    {AvgIngressRate, Ingress1} = update_rate(Now, Timestamp, InCount, Ingress),

    Duration = %% msgs / (msgs/sec) == sec
        case AvgEgressRate == 0 andalso AvgIngressRate == 0 of
            true  -> infinity;
            false -> (RamMsgCountPrev + RamMsgCount) /
                         (2 * (AvgEgressRate + AvgIngressRate))
        end,

    {Duration, set_ram_duration_target(DurationTarget,
                                       State #vqstate {
                                         egress_rate        = Egress1,
                                         avg_egress_rate    = AvgEgressRate,
                                         ingress_rate       = Ingress1,
                                         avg_ingress_rate   = AvgIngressRate,
                                         rate_timestamp     = Now,
                                         in_counter         = 0,
                                         out_counter        = 0,
                                         ram_msg_count_prev = RamMsgCount })}.

needs_sync(#vqstate { on_sync = {_, _, []} }) -> false;
needs_sync(_)                                 -> true.

sync(State) -> tx_commit_index(State).

handle_pre_hibernate(State = #vqstate { index_state = IndexState }) ->
    State #vqstate { index_state = rabbit_queue_index:flush(IndexState) }.

status(#vqstate { q1 = Q1, q2 = Q2, delta = Delta, q3 = Q3, q4 = Q4,
                  len                  = Len,
                  on_sync              = {_, _, From},
                  target_ram_msg_count = TargetRamMsgCount,
                  ram_msg_count        = RamMsgCount,
                  ram_index_count      = RamIndexCount,
                  avg_egress_rate      = AvgEgressRate,
                  avg_ingress_rate     = AvgIngressRate,
                  next_seq_id          = NextSeqId }) ->
    [ {q1                   , queue:len(Q1)},
      {q2                   , bpqueue:len(Q2)},
      {delta                , Delta},
      {q3                   , bpqueue:len(Q3)},
      {q4                   , queue:len(Q4)},
      {len                  , Len},
      {outstanding_txns     , length(From)},
      {target_ram_msg_count , TargetRamMsgCount},
      {ram_msg_count        , RamMsgCount},
      {ram_index_count      , RamIndexCount},
      {avg_egress_rate      , AvgEgressRate},
      {avg_ingress_rate     , AvgIngressRate},
      {next_seq_id          , NextSeqId} ].

%%----------------------------------------------------------------------------
%% Minor helpers
%%----------------------------------------------------------------------------

one_if(true ) -> 1;
one_if(false) -> 0.

msg_status(IsPersistent, SeqId, Msg = #basic_message { guid = Guid }) ->
    #msg_status { seq_id = SeqId, guid = Guid, msg = Msg,
                  is_persistent = IsPersistent, is_delivered = false,
                  msg_on_disk = false, index_on_disk = false }.

maybe_write_delivered(false, _SeqId, IndexState) ->
    IndexState;
maybe_write_delivered(true, SeqId, IndexState) ->
    rabbit_queue_index:deliver(SeqId, IndexState).

accumulate_ack(SeqId, IsPersistent, Guid, {SeqIdsAcc, Dict}) ->
    {case IsPersistent of
         true  -> [SeqId | SeqIdsAcc];
         false -> SeqIdsAcc
     end, rabbit_misc:dict_cons(find_msg_store(IsPersistent), Guid, Dict)}.

record_pending_ack(#msg_status { guid = Guid, seq_id = SeqId,
                                 is_persistent = IsPersistent,
                                 msg_on_disk = MsgOnDisk } = MsgStatus, PA) ->
    AckEntry = case MsgOnDisk of
                   true  -> {IsPersistent, Guid};
                   false -> MsgStatus
               end,
    dict:store(SeqId, AckEntry, PA).

remove_pending_ack(KeepPersistent,
                   State = #vqstate { pending_ack = PA,
                                      index_state = IndexState }) ->
    {{SeqIds, GuidsByStore}, PA1} =
        dict:fold(
          fun (SeqId, {IsPersistent, Guid}, {Acc, PA2}) ->
                  {accumulate_ack(SeqId, IsPersistent, Guid, Acc),
                   case KeepPersistent andalso IsPersistent of
                       true  -> PA2;
                       false -> dict:erase(SeqId, PA2)
                   end};
              (SeqId, #msg_status {}, {Acc, PA2}) ->
                  {Acc, dict:erase(SeqId, PA2)}
          end, {{[], dict:new()}, PA}, PA),
    case KeepPersistent of
        true  -> State1 = State #vqstate { pending_ack = PA1 },
                 case dict:find(?TRANSIENT_MSG_STORE, GuidsByStore) of
                     error       -> State1;
                     {ok, Guids} -> ok = rabbit_msg_store:remove(
                                           ?TRANSIENT_MSG_STORE, Guids),
                                    State1
                 end;
        false -> IndexState1 = rabbit_queue_index:ack(SeqIds, IndexState),
                 ok = dict:fold(fun (MsgStore, Guids, ok) ->
                                        rabbit_msg_store:remove(MsgStore, Guids)
                                end, ok, GuidsByStore),
                 State #vqstate { pending_ack = dict:new(),
                                  index_state = IndexState1 }
    end.

lookup_tx(Txn) ->
    case get({txn, Txn}) of
        undefined -> #tx { pending_messages = [],
                           pending_acks     = [] };
        V         -> V
    end.

store_tx(Txn, Tx) ->
    put({txn, Txn}, Tx).

erase_tx(Txn) ->
    erase({txn, Txn}).

update_rate(Now, Then, Count, {OThen, OCount}) ->
    %% form the avg over the current period and the previous
    Avg = 1000000 * ((Count + OCount) / timer:now_diff(Now, OThen)),
    {Avg, {Then, Count}}.

persistent_guids(Pubs) ->
    [Guid || Obj = #basic_message { guid = Guid } <- Pubs,
             Obj #basic_message.is_persistent].

betas_from_segment_entries(List, TransientThreshold, IndexState) ->
    {Filtered, IndexState1} =
        lists:foldr(
          fun ({Guid, SeqId, IsPersistent, IsDelivered},
               {FilteredAcc, IndexStateAcc}) ->
                  case SeqId < TransientThreshold andalso not IsPersistent of
                      true  -> {FilteredAcc,
                                rabbit_queue_index:ack(
                                  [SeqId], maybe_write_delivered(
                                             not IsDelivered,
                                             SeqId, IndexStateAcc))};
                      false -> {[#msg_status { msg           = undefined,
                                               guid          = Guid,
                                               seq_id        = SeqId,
                                               is_persistent = IsPersistent,
                                               is_delivered  = IsDelivered,
                                               msg_on_disk   = true,
                                               index_on_disk = true
                                             } | FilteredAcc],
                                IndexStateAcc}
                  end
          end, {[], IndexState}, List),
    {bpqueue:from_list([{true, Filtered}]), IndexState1}.

read_one_index_segment(StartSeqId, EndSeqId, IndexState)
  when StartSeqId =< EndSeqId ->
    case rabbit_queue_index:read(StartSeqId, EndSeqId, IndexState) of
        {List, Again, IndexState1} when List /= [] orelse Again =:= undefined ->
            {List, IndexState1,
             rabbit_queue_index:next_segment_boundary(StartSeqId)};
        {[], StartSeqId1, IndexState1} ->
            read_one_index_segment(StartSeqId1, EndSeqId, IndexState1)
    end.

ensure_binary_properties(Msg = #basic_message { content = Content }) ->
    Msg #basic_message {
      content = rabbit_binary_parser:clear_decoded_content(
                  rabbit_binary_generator:ensure_content_encoded(Content)) }.

%% the first arg is the older delta
combine_deltas(?BLANK_DELTA_PATTERN(X), ?BLANK_DELTA_PATTERN(Y)) ->
    ?BLANK_DELTA;
combine_deltas(?BLANK_DELTA_PATTERN(X), #delta { start_seq_id = Start,
                                                 count        = Count,
                                                 end_seq_id   = End } = B) ->
    true = Start + Count =< End, %% ASSERTION
    B;
combine_deltas(#delta { start_seq_id = Start,
                        count        = Count,
                        end_seq_id   = End } = A, ?BLANK_DELTA_PATTERN(Y)) ->
    true = Start + Count =< End, %% ASSERTION
    A;
combine_deltas(#delta { start_seq_id = StartLow,
                        count        = CountLow,
                        end_seq_id   = EndLow },
               #delta { start_seq_id = StartHigh,
                        count        = CountHigh,
                        end_seq_id   = EndHigh }) ->
    Count = CountLow + CountHigh,
    true = (StartLow =< StartHigh) %% ASSERTIONS
        andalso ((StartLow + CountLow) =< EndLow)
        andalso ((StartHigh + CountHigh) =< EndHigh)
        andalso ((StartLow + Count) =< EndHigh),
    #delta { start_seq_id = StartLow, count = Count, end_seq_id = EndHigh }.

beta_fold_no_index_on_disk(Fun, Init, Q) ->
    bpqueue:foldr(fun (_Prefix, Value, Acc) -> Fun(Value, Acc) end, Init, Q).

permitted_ram_index_count(#vqstate { len = 0 }) ->
    undefined;
permitted_ram_index_count(#vqstate { len   = Len,
                                     q2    = Q2,
                                     q3    = Q3,
                                     delta = #delta { count = DeltaCount } }) ->
    AlphaBetaLen = Len - DeltaCount,
    case AlphaBetaLen == 0 of
        true  -> undefined;
        false -> BetaLen = bpqueue:len(Q2) + bpqueue:len(Q3),
                 %% the fraction of the alphas+betas that are betas
                 BetaFrac =  BetaLen / AlphaBetaLen,
                 BetaLen - trunc(BetaFrac * BetaLen)
    end.


should_force_index_to_disk(State =
                           #vqstate { ram_index_count = RamIndexCount }) ->
    case permitted_ram_index_count(State) of
        undefined -> false;
        Permitted -> RamIndexCount >= Permitted
    end.

%%----------------------------------------------------------------------------
%% Internal major helpers for Public API
%%----------------------------------------------------------------------------

ack(_Fun, [], State) ->
    State;
ack(Fun, AckTags, State) ->
    {{SeqIds, GuidsByStore}, State1 = #vqstate { index_state      = IndexState,
                                                 persistent_count = PCount }} =
        lists:foldl(
          fun (SeqId, {Acc, State2 = #vqstate {pending_ack = PA }}) ->
                  {ok, AckEntry} = dict:find(SeqId, PA),
                  {case AckEntry of
                       #msg_status { index_on_disk = false, %% ASSERTIONS
                                     msg_on_disk   = false,
                                     is_persistent = false } ->
                           Acc;
                       {IsPersistent, Guid} ->
                           accumulate_ack(SeqId, IsPersistent, Guid, Acc)
                   end, Fun(AckEntry, State2 #vqstate {
                                        pending_ack = dict:erase(SeqId, PA) })}
          end, {{[], dict:new()}, State}, AckTags),
    IndexState1 = rabbit_queue_index:ack(SeqIds, IndexState),
    ok = dict:fold(fun (MsgStore, Guids, ok) ->
                           rabbit_msg_store:release(MsgStore, Guids)
                   end, ok, GuidsByStore),
    PCount1 = PCount - case dict:find(?PERSISTENT_MSG_STORE, GuidsByStore) of
                           error        -> 0;
                           {ok, Guids} -> length(Guids)
                       end,
    State1 #vqstate { index_state      = IndexState1,
                      persistent_count = PCount1 }.

msg_store_callback(PersistentGuids, IsTransientPubs, Pubs, AckTags, Fun) ->
    Self = self(),
    F = fun () -> rabbit_amqqueue:maybe_run_queue_via_backing_queue(
                    Self, fun (StateN) -> tx_commit_post_msg_store(
                                            IsTransientPubs, Pubs,
                                            AckTags, Fun, StateN)
                          end)
        end,
    fun () -> spawn(fun () -> ok = rabbit_misc:with_exit_handler(
                                     fun () -> rabbit_msg_store:remove(
                                                 ?PERSISTENT_MSG_STORE,
                                                 PersistentGuids)
                                     end, F)
                    end)
    end.

tx_commit_post_msg_store(IsTransientPubs, Pubs, AckTags, Fun,
                         State = #vqstate {
                           on_sync     = OnSync = {SAcks, SPubs, SFuns},
                           pending_ack = PA,
                           durable     = IsDurable }) ->
    %% If we are a non-durable queue, or (no persisent pubs, and no
    %% persistent acks) then we can skip the queue_index loop.
    case (not IsDurable) orelse
        (IsTransientPubs andalso
         lists:foldl(
           fun (AckTag,  true ) ->
                   case dict:find(AckTag, PA) of
                       {ok, #msg_status {}}         -> true;
                       {ok, {IsPersistent, _Guid}} -> not IsPersistent
                   end;
               (_AckTag, false) -> false
           end, true, AckTags)) of
        true  -> State1 = tx_commit_index(State #vqstate {
                                            on_sync = {[], [Pubs], [Fun]} }),
                 State1 #vqstate { on_sync = OnSync };
        false -> State #vqstate { on_sync = { [AckTags | SAcks],
                                              [Pubs | SPubs],
                                              [Fun | SFuns] }}
    end.

tx_commit_index(State = #vqstate { on_sync = {_, _, []} }) ->
    State;
tx_commit_index(State = #vqstate { on_sync = {SAcks, SPubs, SFuns},
                                   durable = IsDurable }) ->
    Acks = lists:flatten(SAcks),
    Pubs = lists:flatten(lists:reverse(SPubs)),
    {SeqIds, State1 = #vqstate { index_state = IndexState }} =
        lists:foldl(
          fun (Msg = #basic_message { is_persistent = IsPersistent },
               {SeqIdsAcc, State2}) ->
                  IsPersistent1 = IsDurable andalso IsPersistent,
                  {SeqId, State3} = publish(Msg, false, IsPersistent1, State2),
                  {case IsPersistent1 of
                       true  -> [SeqId | SeqIdsAcc];
                       false -> SeqIdsAcc
                   end, State3}
          end, {Acks, ack(Acks, State)}, Pubs),
    IndexState1 = rabbit_queue_index:sync(SeqIds, IndexState),
    [ Fun() || Fun <- lists:reverse(SFuns) ],
    State1 #vqstate { index_state = IndexState1, on_sync = {[], [], []} }.

delete1(_TransientThreshold, NextSeqId, DeltaSeqId, IndexState)
  when DeltaSeqId =:= undefined orelse DeltaSeqId >= NextSeqId ->
    IndexState;
delete1(TransientThreshold, NextSeqId, DeltaSeqId, IndexState) ->
    {List, Again, IndexState1} =
        rabbit_queue_index:read(DeltaSeqId, NextSeqId, IndexState),
    IndexState2 =
        case List of
            [] -> IndexState1;
            _  -> {Q, IndexState3} = betas_from_segment_entries(
                                       List, TransientThreshold, IndexState1),
                  {_Count, IndexState4} =
                      remove_queue_entries(
                        fun beta_fold_no_index_on_disk/3, Q, IndexState3),
                  IndexState4
        end,
    delete1(TransientThreshold, NextSeqId, Again, IndexState2).

purge1(Count, State = #vqstate { q3 = Q3, index_state = IndexState }) ->
    case bpqueue:is_empty(Q3) of
        true  -> {Q1Count, IndexState1} =
                     remove_queue_entries(fun rabbit_misc:queue_fold/3,
                                          State #vqstate.q1, IndexState),
                 {Count + Q1Count,
                  State #vqstate { q1          = queue:new(),
                                   index_state = IndexState1 }};
        false -> {Q3Count, IndexState1} =
                     remove_queue_entries(fun beta_fold_no_index_on_disk/3,
                                          Q3, IndexState),
                 purge1(Count + Q3Count,
                        maybe_deltas_to_betas(
                          State #vqstate { q3          = bpqueue:new(),
                                           index_state = IndexState1 }))
    end.

remove_queue_entries(Fold, Q, IndexState) ->
    {Count, GuidsByStore, SeqIds, IndexState1} =
        Fold(fun remove_queue_entries1/2, {0, dict:new(), [], IndexState}, Q),
    ok = dict:fold(fun (MsgStore, Guids, ok) ->
                           rabbit_msg_store:remove(MsgStore, Guids)
                   end, ok, GuidsByStore),
    {Count, case SeqIds of
                [] -> IndexState1;
                _  -> rabbit_queue_index:ack(SeqIds, IndexState1)
            end}.

remove_queue_entries1(
  #msg_status { guid = Guid, seq_id = SeqId,
                is_delivered = IsDelivered, msg_on_disk = MsgOnDisk,
                index_on_disk = IndexOnDisk, is_persistent = IsPersistent },
  {Count, GuidsByStore, SeqIdsAcc, IndexState}) ->
    GuidsByStore1 = case MsgOnDisk of
                        true  -> rabbit_misc:dict_cons(
                                   find_msg_store(IsPersistent),
                                   Guid, GuidsByStore);
                        false -> GuidsByStore
                    end,
    SeqIdsAcc1 = case IndexOnDisk of
                     true  -> [SeqId | SeqIdsAcc];
                     false -> SeqIdsAcc
                 end,
    IndexState1 = maybe_write_delivered(
                    IndexOnDisk andalso not IsDelivered,
                    SeqId, IndexState),
    {Count + 1, GuidsByStore1, SeqIdsAcc1, IndexState1}.

fetch_from_q3_or_delta(State = #vqstate {
                         q1                = Q1,
                         q2                = Q2,
                         delta             = #delta { count = DeltaCount },
                         q3                = Q3,
                         q4                = Q4,
                         ram_msg_count     = RamMsgCount,
                         ram_index_count   = RamIndexCount,
                         msg_store_clients = MSCState }) ->
    case bpqueue:out(Q3) of
        {empty, _Q3} ->
            0 = DeltaCount, %% ASSERTION
            true = bpqueue:is_empty(Q2), %% ASSERTION
            true = queue:is_empty(Q1), %% ASSERTION
            {empty, State};
        {{value, IndexOnDisk, MsgStatus = #msg_status {
                                msg = undefined, guid = Guid,
                                is_persistent = IsPersistent }}, Q3a} ->
            {{ok, Msg = #basic_message { is_persistent = IsPersistent,
                                         guid = Guid }}, MSCState1} =
                read_from_msg_store(MSCState, IsPersistent, Guid),
            Q4a = queue:in(MsgStatus #msg_status { msg = Msg }, Q4),
            RamIndexCount1 = RamIndexCount - one_if(not IndexOnDisk),
            true = RamIndexCount1 >= 0, %% ASSERTION
            State1 = State #vqstate { q3                = Q3a,
                                      q4                = Q4a,
                                      ram_msg_count     = RamMsgCount + 1,
                                      ram_index_count   = RamIndexCount1,
                                      msg_store_clients = MSCState1 },
            State2 =
                case {bpqueue:is_empty(Q3a), 0 == DeltaCount} of
                    {true, true} ->
                        %% q3 is now empty, it wasn't before; delta is
                        %% still empty. So q2 must be empty, and q1
                        %% can now be joined onto q4
                        true = bpqueue:is_empty(Q2), %% ASSERTION
                        State1 #vqstate { q1 = queue:new(),
                                          q4 = queue:join(Q4a, Q1) };
                    {true, false} ->
                        maybe_deltas_to_betas(State1);
                    {false, _} ->
                        %% q3 still isn't empty, we've not touched
                        %% delta, so the invariants between q1, q2,
                        %% delta and q3 are maintained
                        State1
                end,
            {loaded, State2}
    end.

reduce_memory_use(State = #vqstate {
                    ram_msg_count        = RamMsgCount,
                    target_ram_msg_count = TargetRamMsgCount })
  when TargetRamMsgCount == undefined orelse TargetRamMsgCount >= RamMsgCount ->
    State;
reduce_memory_use(State = #vqstate {
                    target_ram_msg_count = TargetRamMsgCount }) ->
    State1 = maybe_push_q4_to_betas(maybe_push_q1_to_betas(State)),
    case TargetRamMsgCount of
        0 -> push_betas_to_deltas(State1);
        _ -> State1
    end.

%%----------------------------------------------------------------------------
%% Internal gubbins for publishing
%%----------------------------------------------------------------------------

msg_storage_type(_SeqId, #vqstate { target_ram_msg_count = TargetRamMsgCount,
                                    ram_msg_count        = RamMsgCount })
  when TargetRamMsgCount == undefined orelse TargetRamMsgCount > RamMsgCount ->
    msg;
msg_storage_type( SeqId, #vqstate { target_ram_msg_count = 0, q3 = Q3 }) ->
    case bpqueue:out(Q3) of
        {empty, _Q3} ->
            %% if TargetRamMsgCount == 0, we know we have no
            %% alphas. If q3 is empty then delta must be empty too, so
            %% create a beta, which should end up in q3
            index;
        {{value, _IndexOnDisk, #msg_status { seq_id = OldSeqId }}, _Q3a} ->
            %% Don't look at the current delta as it may be empty. If
            %% the SeqId is still within the current segment, it'll be
            %% a beta, else it'll go into delta
            case SeqId >= rabbit_queue_index:next_segment_boundary(OldSeqId) of
                true  -> neither;
                false -> index
            end
    end;
msg_storage_type(_SeqId, #vqstate { q1 = Q1 }) ->
    case queue:is_empty(Q1) of
        true  -> index;
        %% Can push out elders (in q1) to disk. This may also result
        %% in the msg itself going to disk and q2/q3.
        false -> msg
    end.

publish(Msg = #basic_message { is_persistent = IsPersistent },
        IsDelivered, MsgOnDisk,
        State = #vqstate { next_seq_id      = SeqId,
                           len              = Len,
                           in_counter       = InCount,
                           persistent_count = PCount,
                           durable          = IsDurable }) ->
    IsPersistent1 = IsDurable andalso IsPersistent,
    MsgStatus = (msg_status(IsPersistent1, SeqId, Msg))
        #msg_status { is_delivered = IsDelivered, msg_on_disk = MsgOnDisk },
    PCount1 = PCount + one_if(IsPersistent1),
    {SeqId, publish(msg_storage_type(SeqId, State), MsgStatus,
                    State #vqstate { next_seq_id      = SeqId   + 1,
                                     len              = Len     + 1,
                                     in_counter       = InCount + 1,
                                     persistent_count = PCount1 })}.

publish(msg, MsgStatus, State) ->
    {MsgStatus1, State1 = #vqstate { ram_msg_count = RamMsgCount }} =
        maybe_write_to_disk(false, false, MsgStatus, State),
    State2 = State1 # vqstate {ram_msg_count = RamMsgCount + 1 },
    store_alpha_entry(MsgStatus1, State2);

publish(index, MsgStatus, State) ->
    ForceIndex = should_force_index_to_disk(State),
    {MsgStatus1 = #msg_status { msg_on_disk = true,
                                index_on_disk = IndexOnDisk },
     State1 = #vqstate { ram_index_count = RamIndexCount, q1 = Q1 }} =
        maybe_write_to_disk(true, ForceIndex, MsgStatus, State),
    RamIndexCount1 = RamIndexCount + one_if(not IndexOnDisk),
    State2 = State1 #vqstate { ram_index_count = RamIndexCount1 },
    true = queue:is_empty(Q1), %% ASSERTION
    store_beta_entry(MsgStatus1, State2);

publish(neither, MsgStatus, State) ->
    {#msg_status { msg_on_disk = true, index_on_disk = true, seq_id = SeqId },
     State1 = #vqstate { q1 = Q1, q2 = Q2, delta = Delta }} =
        maybe_write_to_disk(true, true, MsgStatus, State),
    true = queue:is_empty(Q1) andalso bpqueue:is_empty(Q2), %% ASSERTION
    Delta1 = #delta { start_seq_id = SeqId,
                      count        = 1,
                      end_seq_id   = SeqId + 1 },
    State1 #vqstate { delta = combine_deltas(Delta, Delta1) }.

store_alpha_entry(MsgStatus, State = #vqstate {
                               q1    = Q1,
                               q2    = Q2,
                               delta = #delta { count = DeltaCount },
                               q3    = Q3,
                               q4    = Q4 }) ->
    case bpqueue:is_empty(Q2) andalso 0 == DeltaCount andalso
        bpqueue:is_empty(Q3) of
        true  -> true = queue:is_empty(Q1), %% ASSERTION
                 State #vqstate { q4 = queue:in(MsgStatus, Q4) };
        false -> maybe_push_q1_to_betas(
                   State #vqstate { q1 = queue:in(MsgStatus, Q1) })
    end.

store_beta_entry(MsgStatus = #msg_status { msg_on_disk = true,
                                           index_on_disk = IndexOnDisk },
                 State = #vqstate { q2    = Q2,
                                    delta = #delta { count = DeltaCount },
                                    q3    = Q3 }) ->
    MsgStatus1 = MsgStatus #msg_status { msg = undefined },
    case DeltaCount == 0 of
        true  -> State #vqstate { q3 = bpqueue:in(IndexOnDisk, MsgStatus1,
                                                  Q3) };
        false -> State #vqstate { q2 = bpqueue:in(IndexOnDisk, MsgStatus1,
                                                  Q2) }
    end.

find_msg_store(true)  -> ?PERSISTENT_MSG_STORE;
find_msg_store(false) -> ?TRANSIENT_MSG_STORE.

with_msg_store_state({{MSCStateP, PRef}, MSCStateT}, true, Fun) ->
    {Result, MSCStateP1} = Fun(?PERSISTENT_MSG_STORE, MSCStateP),
    {Result, {{MSCStateP1, PRef}, MSCStateT}};
with_msg_store_state({MSCStateP, {MSCStateT, TRef}}, false, Fun) ->
    {Result, MSCStateT1} = Fun(?TRANSIENT_MSG_STORE, MSCStateT),
    {Result, {MSCStateP, {MSCStateT1, TRef}}}.

read_from_msg_store(MSCState, IsPersistent, Guid) ->
    with_msg_store_state(
      MSCState, IsPersistent,
      fun (MsgStore, MSCState1) ->
              rabbit_msg_store:read(MsgStore, Guid, MSCState1)
      end).

maybe_write_msg_to_disk(_Force, MsgStatus =
                        #msg_status { msg_on_disk = true }, MSCState) ->
    {MsgStatus, MSCState};
maybe_write_msg_to_disk(Force, MsgStatus = #msg_status {
                                 msg = Msg, guid = Guid,
                                 is_persistent = IsPersistent }, MSCState)
  when Force orelse IsPersistent ->
    {ok, MSCState1} =
        with_msg_store_state(
          MSCState, IsPersistent,
          fun (MsgStore, MSCState2) ->
                  rabbit_msg_store:write(
                    MsgStore, Guid, ensure_binary_properties(Msg), MSCState2)
          end),
    {MsgStatus #msg_status { msg_on_disk = true }, MSCState1};
maybe_write_msg_to_disk(_Force, MsgStatus, MSCState) ->
    {MsgStatus, MSCState}.

maybe_write_index_to_disk(_Force, MsgStatus =
                          #msg_status { index_on_disk = true }, IndexState) ->
    true = MsgStatus #msg_status.msg_on_disk, %% ASSERTION
    {MsgStatus, IndexState};
maybe_write_index_to_disk(Force, MsgStatus = #msg_status {
                                   guid = Guid, seq_id = SeqId,
                                   is_persistent = IsPersistent,
                                   is_delivered = IsDelivered }, IndexState)
  when Force orelse IsPersistent ->
    true = MsgStatus #msg_status.msg_on_disk, %% ASSERTION
    IndexState1 = rabbit_queue_index:publish(Guid, SeqId, IsPersistent,
                                             IndexState),
    {MsgStatus #msg_status { index_on_disk = true },
     maybe_write_delivered(IsDelivered, SeqId, IndexState1)};
maybe_write_index_to_disk(_Force, MsgStatus, IndexState) ->
    {MsgStatus, IndexState}.

maybe_write_to_disk(ForceMsg, ForceIndex, MsgStatus,
                    State = #vqstate { index_state       = IndexState,
                                       msg_store_clients = MSCState }) ->
    {MsgStatus1, MSCState1}   = maybe_write_msg_to_disk(
                                  ForceMsg, MsgStatus, MSCState),
    {MsgStatus2, IndexState1} = maybe_write_index_to_disk(
                                  ForceIndex, MsgStatus1, IndexState),
    {MsgStatus2, State #vqstate { index_state       = IndexState1,
                                  msg_store_clients = MSCState1 }}.

%%----------------------------------------------------------------------------
%% Phase changes
%%----------------------------------------------------------------------------

limit_ram_index(State = #vqstate { ram_index_count = RamIndexCount }) ->
    case permitted_ram_index_count(State) of
        undefined ->
            State;
        Permitted when RamIndexCount > Permitted ->
            Reduction = lists:min([RamIndexCount - Permitted,
                                   ?RAM_INDEX_BATCH_SIZE]),
            case Reduction < ?RAM_INDEX_BATCH_SIZE of
                true  -> State;
                false -> {Reduction1, State1} =
                             limit_q2_ram_index(Reduction, State),
                         {_Red2, State2} =
                             limit_q3_ram_index(Reduction1, State1),
                         State2
            end;
        _ ->
            State
    end.

limit_q2_ram_index(Reduction, State = #vqstate { q2 = Q2 })
  when Reduction > 0 ->
    {Q2a, Reduction1, State1} = limit_ram_index(fun bpqueue:map_fold_filter_l/4,
                                                Q2, Reduction, State),
    {Reduction1, State1 #vqstate { q2 = Q2a }};
limit_q2_ram_index(Reduction, State) ->
    {Reduction, State}.

limit_q3_ram_index(Reduction, State = #vqstate { q3 = Q3 })
  when Reduction > 0 ->
    %% use the _r version so that we prioritise the msgs closest to
    %% delta, and least soon to be delivered
    {Q3a, Reduction1, State1} = limit_ram_index(fun bpqueue:map_fold_filter_r/4,
                                                Q3, Reduction, State),
    {Reduction1, State1 #vqstate { q3 = Q3a }};
limit_q3_ram_index(Reduction, State) ->
    {Reduction, State}.

limit_ram_index(MapFoldFilterFun, Q, Reduction,
                State = #vqstate { ram_index_count = RamIndexCount,
                                   index_state     = IndexState }) ->
    {Qa, {Reduction1, IndexState1}} =
        MapFoldFilterFun(
          fun erlang:'not'/1,
          fun (MsgStatus, {0, _IndexStateN}) ->
                  false = MsgStatus #msg_status.index_on_disk, %% ASSERTION
                  stop;
              (MsgStatus, {N, IndexStateN}) when N > 0 ->
                  false = MsgStatus #msg_status.index_on_disk, %% ASSERTION
                  {MsgStatus1, IndexStateN1} =
                      maybe_write_index_to_disk(true, MsgStatus, IndexStateN),
                  {true, MsgStatus1, {N-1, IndexStateN1}}
          end, {Reduction, IndexState}, Q),
    RamIndexCount1 = RamIndexCount - (Reduction - Reduction1),
    {Qa, Reduction1, State #vqstate { index_state     = IndexState1,
                                      ram_index_count = RamIndexCount1 }}.

maybe_deltas_to_betas(State = #vqstate { delta = ?BLANK_DELTA_PATTERN(X) }) ->
    State;
maybe_deltas_to_betas(State = #vqstate {
                        q2                   = Q2,
                        delta                = Delta,
                        q3                   = Q3,
                        index_state          = IndexState,
                        target_ram_msg_count = TargetRamMsgCount,
                        transient_threshold  = TransientThreshold }) ->
    case (not bpqueue:is_empty(Q3)) andalso (0 == TargetRamMsgCount) of
        true ->
            State;
        false ->
            %% either q3 is empty, in which case we load at least one
            %% segment, or TargetRamMsgCount > 0, meaning we should
            %% really be holding all the betas in memory.
            #delta { start_seq_id = DeltaSeqId,
                     count        = DeltaCount,
                     end_seq_id   = DeltaSeqIdEnd } = Delta,
            {List, IndexState1, Delta1SeqId} =
                read_one_index_segment(DeltaSeqId, DeltaSeqIdEnd, IndexState),
            %% length(List) may be < segment_size because of acks.  It
            %% could be [] if we ignored every message in the segment
            %% due to it being transient and below the threshold
            {Q3a, IndexState2} = betas_from_segment_entries(
                                   List, TransientThreshold, IndexState1),
            State1 = State #vqstate { index_state = IndexState2 },
            case bpqueue:len(Q3a) of
                0 ->
                    maybe_deltas_to_betas(
                      State #vqstate {
                        delta = Delta #delta { start_seq_id = Delta1SeqId }});
                Q3aLen ->
                    Q3b = bpqueue:join(Q3, Q3a),
                    case DeltaCount - Q3aLen of
                        0 ->
                            %% delta is now empty, but it wasn't
                            %% before, so can now join q2 onto q3
                            State1 #vqstate { q2    = bpqueue:new(),
                                              delta = ?BLANK_DELTA,
                                              q3    = bpqueue:join(Q3b, Q2) };
                        N when N > 0 ->
                            Delta1 = #delta { start_seq_id = Delta1SeqId,
                                              count        = N,
                                              end_seq_id   = DeltaSeqIdEnd },
                            State1 #vqstate { delta = Delta1,
                                              q3    = Q3b }
                    end
            end
    end.

maybe_push_q1_to_betas(State = #vqstate { q1 = Q1 }) ->
    maybe_push_alphas_to_betas(
      fun queue:out/1,
      fun (MsgStatus, Q1a, State1) ->
              %% these could legally go to q3 if delta and q2 are empty
              store_beta_entry(MsgStatus, State1 #vqstate { q1 = Q1a })
      end, Q1, State).

maybe_push_q4_to_betas(State = #vqstate { q4 = Q4 }) ->
    maybe_push_alphas_to_betas(
      fun queue:out_r/1,
      fun (MsgStatus = #msg_status { index_on_disk = IndexOnDisk },
           Q4a, State1 = #vqstate { q3 = Q3 }) ->
              MsgStatus1 = MsgStatus #msg_status { msg = undefined },
              %% these must go to q3
              State1 #vqstate { q3 = bpqueue:in_r(IndexOnDisk, MsgStatus1, Q3),
                                q4 = Q4a }
      end, Q4, State).

maybe_push_alphas_to_betas(_Generator, _Consumer, _Q,
                           State = #vqstate {
                             ram_msg_count        = RamMsgCount,
                             target_ram_msg_count = TargetRamMsgCount })
  when TargetRamMsgCount == undefined orelse TargetRamMsgCount >= RamMsgCount ->
    State;
maybe_push_alphas_to_betas(Generator, Consumer, Q, State) ->
    case Generator(Q) of
        {empty, _Q} -> State;
        {{value, MsgStatus}, Qa} ->
            ForceIndex = should_force_index_to_disk(State),
            {MsgStatus1 = #msg_status { msg_on_disk = true,
                                        index_on_disk = IndexOnDisk },
             State1 = #vqstate { ram_msg_count   = RamMsgCount,
                                 ram_index_count = RamIndexCount }} =
                maybe_write_to_disk(true, ForceIndex, MsgStatus, State),
            RamIndexCount1 = RamIndexCount + one_if(not IndexOnDisk),
            State2 = State1 #vqstate { ram_msg_count = RamMsgCount - 1,
                                       ram_index_count = RamIndexCount1 },
            maybe_push_alphas_to_betas(Generator, Consumer, Qa,
                                       Consumer(MsgStatus1, Qa, State2))
    end.

push_betas_to_deltas(State = #vqstate { q2              = Q2,
                                        delta           = Delta,
                                        q3              = Q3,
                                        ram_index_count = RamIndexCount,
                                        index_state     = IndexState }) ->
    %% HighSeqId is high in the sense that it must be higher than the
    %% seq_id in Delta, but it's also the lowest of the betas that we
    %% transfer from q2 to delta.
    {HighSeqId, Len1, Q2a, RamIndexCount1, IndexState1} =
        push_betas_to_deltas(
          fun bpqueue:out/1, undefined, Q2, RamIndexCount, IndexState),
    true = bpqueue:is_empty(Q2a), %% ASSERTION
    EndSeqId =
        case bpqueue:out_r(Q2) of
            {empty, _Q2} ->
                undefined;
            {{value, _IndexOnDisk, #msg_status { seq_id = EndSeqId1 }}, _Q2} ->
                EndSeqId1 + 1
        end,
    Delta1 = #delta { start_seq_id = Delta1SeqId } =
        combine_deltas(Delta, #delta { start_seq_id = HighSeqId,
                                       count        = Len1,
                                       end_seq_id   = EndSeqId }),
    State1 = State #vqstate { q2              = bpqueue:new(),
                              delta           = Delta1,
                              index_state     = IndexState1,
                              ram_index_count = RamIndexCount1 },
    case bpqueue:out(Q3) of
        {empty, _Q3} ->
            State1;
        {{value, _IndexOnDisk1, #msg_status { seq_id = SeqId }}, _Q3} ->
            {{value, _IndexOnDisk2, #msg_status { seq_id = SeqIdMax }}, _Q3a} =
                bpqueue:out_r(Q3),
            Limit = rabbit_queue_index:next_segment_boundary(SeqId),
            %% ASSERTION
            true = Delta1SeqId == undefined orelse Delta1SeqId > SeqIdMax,
            case SeqIdMax < Limit of
                true -> %% already only holding LTE one segment indices in q3
                    State1;
                false ->
                    %% SeqIdMax is low in the sense that it must be
                    %% lower than the seq_id in delta1, in fact either
                    %% delta1 has undefined as its seq_id or there
                    %% does not exist a seq_id X s.t. X > SeqIdMax and
                    %% X < delta1's seq_id (would be +1 if it wasn't
                    %% for the possibility of gaps in the seq_ids).
                    %% But because we use queue:out_r, SeqIdMax is
                    %% actually also the highest seq_id of the betas we
                    %% transfer from q3 to deltas.
                    {SeqIdMax, Len2, Q3a, RamIndexCount2, IndexState2} =
                        push_betas_to_deltas(fun bpqueue:out_r/1, Limit, Q3,
                                             RamIndexCount1, IndexState1),
                    Delta2 = #delta { start_seq_id = Limit,
                                      count        = Len2,
                                      end_seq_id   = SeqIdMax + 1 },
                    Delta3 = combine_deltas(Delta2, Delta1),
                    State1 #vqstate { delta           = Delta3,
                                      q3              = Q3a,
                                      index_state     = IndexState2,
                                      ram_index_count = RamIndexCount2 }
            end
    end.

push_betas_to_deltas(Generator, Limit, Q, RamIndexCount, IndexState) ->
    case Generator(Q) of
        {empty, Qa} -> {undefined, 0, Qa, RamIndexCount, IndexState};
        {{value, _IndexOnDisk, #msg_status { seq_id = SeqId }}, _Qa} ->
            {Count, Qb, RamIndexCount1, IndexState1} =
                push_betas_to_deltas(
                  Generator, Limit, Q, 0, RamIndexCount, IndexState),
            {SeqId, Count, Qb, RamIndexCount1, IndexState1}
    end.

push_betas_to_deltas(Generator, Limit, Q, Count, RamIndexCount, IndexState) ->
    case Generator(Q) of
        {empty, Qa} ->
            {Count, Qa, RamIndexCount, IndexState};
        {{value, _IndexOnDisk, #msg_status { seq_id = SeqId }}, _Qa}
        when Limit =/= undefined andalso SeqId < Limit ->
            {Count, Q, RamIndexCount, IndexState};
        {{value, IndexOnDisk, MsgStatus}, Qa} ->
            {RamIndexCount1, IndexState1} =
                case IndexOnDisk of
                    true ->
                        {RamIndexCount, IndexState};
                    false ->
                        {#msg_status { index_on_disk = true }, IndexState2} =
                            maybe_write_index_to_disk(true, MsgStatus,
                                                      IndexState),
                        {RamIndexCount - 1, IndexState2}
                end,
            push_betas_to_deltas(
              Generator, Limit, Qa, Count + 1, RamIndexCount1, IndexState1)
    end.
