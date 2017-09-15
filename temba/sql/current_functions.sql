-- Generated by collect_sql on 2017-09-14 19:26 UTC

----------------------------------------------------------------------
-- Trigger procedure to prevent illegal state changes to contacts
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contact_check_update() RETURNS TRIGGER AS $$
BEGIN
  IF OLD.is_test != NEW.is_test THEN
    RAISE EXCEPTION 'Contact.is_test cannot be changed';
  END IF;

  IF NEW.is_test AND (NEW.is_blocked OR NEW.is_stopped) THEN
    RAISE EXCEPTION 'Test contacts cannot opt out or be blocked';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Convenience method to call contact_toggle_system_group with a row
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION
  contact_toggle_system_group(_contact contacts_contact, _group_type CHAR(1), _add BOOLEAN)
RETURNS VOID AS $$
DECLARE
  _group_id INT;
BEGIN
  PERFORM contact_toggle_system_group(_contact.id, _contact.org_id, _group_type, _add);
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Determines the (mutually exclusive) system label for a broadcast record
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_broadcast_determine_system_label(_broadcast msgs_broadcast) RETURNS CHAR(1) AS $$
BEGIN
  IF _broadcast.is_active AND _broadcast.schedule_id IS NOT NULL THEN
    RETURN 'E';
  END IF;

  RETURN NULL; -- might not match any label
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Trigger procedure to update system labels on broadcast changes
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_broadcast_on_change() RETURNS TRIGGER AS $$
DECLARE
  _is_test BOOLEAN;
  _new_label_type CHAR(1);
  _old_label_type CHAR(1);
BEGIN
  -- new broadcast inserted
  IF TG_OP = 'INSERT' THEN
    -- don't update anything for a test broadcast
    IF NEW.recipient_count = 1 THEN
      SELECT c.is_test INTO _is_test FROM contacts_contact c
      INNER JOIN msgs_msg m ON m.contact_id = c.id AND m.broadcast_id = NEW.id;
      IF _is_test = TRUE THEN
        RETURN NULL;
      END IF;
    END IF;

    _new_label_type := temba_broadcast_determine_system_label(NEW);
    IF _new_label_type IS NOT NULL THEN
      PERFORM temba_insert_system_label(NEW.org_id, _new_label_type, 1);
    END IF;

  -- existing broadcast updated
  ELSIF TG_OP = 'UPDATE' THEN
    _old_label_type := temba_broadcast_determine_system_label(OLD);
    _new_label_type := temba_broadcast_determine_system_label(NEW);

    IF _old_label_type IS DISTINCT FROM _new_label_type THEN
      -- if this could be a test broadcast, check it and exit if so
      IF NEW.recipient_count = 1 THEN
        SELECT c.is_test INTO _is_test FROM contacts_contact c
        INNER JOIN msgs_msg m ON m.contact_id = c.id AND m.broadcast_id = NEW.id;
        IF _is_test = TRUE THEN
          RETURN NULL;
        END IF;
      END IF;

      IF _old_label_type IS NOT NULL THEN
        PERFORM temba_insert_system_label(OLD.org_id, _old_label_type, -1);
      END IF;
      IF _new_label_type IS NOT NULL THEN
        PERFORM temba_insert_system_label(NEW.org_id, _new_label_type, 1);
      END IF;
    END IF;

  -- existing broadcast deleted
  ELSIF TG_OP = 'DELETE' THEN
    -- don't update anything for a test broadcast
    IF OLD.recipient_count = 1 THEN
      SELECT c.is_test INTO _is_test FROM contacts_contact c
      INNER JOIN msgs_msg m ON m.contact_id = c.id AND m.broadcast_id = OLD.id;
      IF _is_test = TRUE THEN
        RETURN NULL;
      END IF;
    END IF;

    _old_label_type := temba_broadcast_determine_system_label(OLD);

    IF _old_label_type IS NOT NULL THEN
      PERFORM temba_insert_system_label(OLD.org_id, _old_label_type, 1);
    END IF;

  -- all broadcast deleted
  ELSIF TG_OP = 'TRUNCATE' THEN
    PERFORM temba_reset_system_labels('{"E"}');

  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION temba_channelevent_is_call(_event channels_channelevent) RETURNS BOOLEAN AS $$
BEGIN
  RETURN _event.event_type IN ('mo_call', 'mo_miss', 'mt_call', 'mt_miss');
END;
$$ LANGUAGE plpgsql;

-- Trigger procedure to update system labels on channel event changes
CREATE OR REPLACE FUNCTION temba_channelevent_on_change() RETURNS TRIGGER AS $$
BEGIN
  -- new event inserted
  IF TG_OP = 'INSERT' THEN
    -- don't update anything for a non-call event or test call
    IF NOT temba_channelevent_is_call(NEW) OR temba_contact_is_test(NEW.contact_id) THEN
      RETURN NULL;
    END IF;

    PERFORM temba_insert_system_label(NEW.org_id, 'C', 1);

  -- existing call updated
  ELSIF TG_OP = 'UPDATE' THEN
    -- don't update anything for a non-call event or test call
    IF NOT temba_channelevent_is_call(NEW) OR temba_contact_is_test(NEW.contact_id) THEN
      RETURN NULL;
    END IF;

  -- existing call deleted
  ELSIF TG_OP = 'DELETE' THEN
    -- don't update anything for a non-call event or test call
    IF NOT temba_channelevent_is_call(OLD) OR temba_contact_is_test(OLD.contact_id) THEN
      RETURN NULL;
    END IF;

    PERFORM temba_insert_system_label(OLD.org_id, 'C', -1);

  -- all calls deleted
  ELSIF TG_OP = 'TRUNCATE' THEN
    PERFORM temba_reset_system_labels('{"C"}');

  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Utility function to lookup whether a contact is a simulator contact
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_contact_is_test(_contact_id INT) RETURNS BOOLEAN AS $$
DECLARE
  _is_test BOOLEAN;
BEGIN
  SELECT is_test INTO STRICT _is_test FROM contacts_contact WHERE id = _contact_id;
  RETURN _is_test;
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Utility function to fetch the flow id from a run
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_flow_for_run(_run_id INT) RETURNS INTEGER AS $$
DECLARE
  _flow_id INTEGER;
BEGIN
  SELECT flow_id INTO STRICT _flow_id FROM flows_flowrun WHERE id = _run_id;
  RETURN _flow_id;
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
----------------------------------------------------------------------
-- Triggers for managing FlowPathCount squashing
----------------------------------------------------------------------
----------------------------------------------------------------------

----------------------------------------------------------------------
-- Utility function to lookup whether a contact is a simulator contact
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_flows_contact_is_test(_contact_id INT) RETURNS BOOLEAN AS $$
DECLARE
  _is_test BOOLEAN;
BEGIN
  SELECT is_test INTO STRICT _is_test FROM contacts_contact WHERE id = _contact_id;
  RETURN _is_test;
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Inserts a new channelcount row with the given values
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_insert_channelcount(_channel_id INTEGER, _count_type VARCHAR(2), _count_day DATE, _count INT) RETURNS VOID AS $$
  BEGIN
    INSERT INTO channels_channelcount("channel_id", "count_type", "day", "count", "is_squashed")
      VALUES(_channel_id, _count_type, _count_day, _count, FALSE);
  END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Inserts a new FlowNodeCount
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_insert_flownodecount(_flow_id INTEGER, _node_uuid UUID, _count INTEGER) RETURNS VOID AS $$
  BEGIN
    INSERT INTO flows_flownodecount("flow_id", "node_uuid", "count", "is_squashed")
      VALUES(_flow_id, _node_uuid, _count, FALSE);
  END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Inserts a new flowpathcount
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_insert_flowpathcount(_flow_id INTEGER, _from_uuid UUID, _to_uuid UUID, _period TIMESTAMP WITH TIME ZONE, _count INTEGER) RETURNS VOID AS $$
  BEGIN
    INSERT INTO flows_flowpathcount("flow_id", "from_uuid", "to_uuid", "period", "count", "is_squashed")
      VALUES(_flow_id, _from_uuid, _to_uuid, date_trunc('hour', _period), _count, FALSE);
  END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Inserts a new flowrun_count
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION
  temba_insert_flowruncount(_flow_id INT, _exit_type CHAR(1), _count INT)
RETURNS VOID AS $$
BEGIN
  INSERT INTO flows_flowruncount("flow_id", "exit_type", "count", "is_squashed")
  VALUES(_flow_id, _exit_type, _count, FALSE);
END;
$$ LANGUAGE plpgsql;

---------------------------------------------------------------------------------
-- Increment or decrement a label count
---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION
  temba_insert_label_count(_label_id INT, _count INT)
RETURNS VOID AS $$
BEGIN
  INSERT INTO msgs_labelcount("label_id", "count", "is_squashed") VALUES(_label_id, _count, FALSE);
END;
$$ LANGUAGE plpgsql;

---------------------------------------------------------------------------------
-- Increment or decrement all of a message's labels
---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION
  temba_insert_message_label_counts(_msg_id INT, _count INT)
RETURNS VOID AS $$
BEGIN
  INSERT INTO msgs_labelcount("label_id", "count", "is_squashed")
  SELECT label_id, _count, FALSE FROM msgs_msg_labels WHERE msgs_msg_labels.msg_id = _msg_id;
END;
$$ LANGUAGE plpgsql;

---------------------------------------------------------------------------------
-- Increment or decrement a system label count
---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION
  temba_insert_system_label(_org_id INT, _label_type CHAR(1), _count INT)
RETURNS VOID AS $$
BEGIN
  INSERT INTO msgs_systemlabelcount("org_id", "label_type", "count", "is_squashed") VALUES(_org_id, _label_type, _count, FALSE);
END;
$$ LANGUAGE plpgsql;

---------------------------------------------------------------------------------
-- Increment or decrement the credits used on a topup
---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION
  temba_insert_topupcredits(_topup_id INT, _count INT)
RETURNS VOID AS $$
BEGIN
  INSERT INTO orgs_topupcredits("topup_id", "used", "is_squashed") VALUES(_topup_id, _count, FALSE);
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Determines the (mutually exclusive) system label for a msg record
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_msg_determine_system_label(_msg msgs_msg) RETURNS CHAR(1) AS $$
BEGIN
  IF _msg.direction = 'I' THEN
    IF _msg.visibility = 'V' THEN
      IF _msg.msg_type = 'I' THEN
        RETURN 'I';
      ELSIF _msg.msg_type = 'F' THEN
        RETURN 'W';
      END IF;
    ELSIF _msg.visibility = 'A' THEN
      RETURN 'A';
    END IF;
  ELSE
    IF _msg.VISIBILITY = 'V' THEN
      IF _msg.status = 'P' OR _msg.status = 'Q' THEN
        RETURN 'O';
      ELSIF _msg.status = 'W' OR _msg.status = 'S' OR _msg.status = 'D' THEN
        RETURN 'S';
      ELSIF _msg.status = 'F' THEN
        RETURN 'X';
      END IF;
    END IF;
  END IF;

  RETURN NULL; -- might not match any label
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Trigger procedure to maintain user label counts
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_msg_labels_on_change() RETURNS TRIGGER AS $$
DECLARE
  is_visible BOOLEAN;
BEGIN
  -- label applied to message
  IF TG_OP = 'INSERT' THEN
    -- is this message visible
    SELECT msgs_msg.visibility = 'V' INTO STRICT is_visible FROM msgs_msg WHERE msgs_msg.id = NEW.msg_id;

    IF is_visible THEN
      PERFORM temba_insert_label_count(NEW.label_id, 1);
    END IF;

  -- label removed from message
  ELSIF TG_OP = 'DELETE' THEN
    -- is this message visible
    SELECT msgs_msg.visibility = 'V' INTO STRICT is_visible FROM msgs_msg WHERE msgs_msg.id = OLD.msg_id;

    IF is_visible THEN
      PERFORM temba_insert_label_count(OLD.label_id, -1);
    END IF;

  -- no more labels for any messages
  ELSIF TG_OP = 'TRUNCATE' THEN
    TRUNCATE msgs_labelcount;

  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Trigger procedure to update user and system labels on column changes
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_msg_on_change() RETURNS TRIGGER AS $$
DECLARE
  _is_test BOOLEAN;
  _new_label_type CHAR(1);
  _old_label_type CHAR(1);
BEGIN
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    -- prevent illegal message states
    IF NEW.direction = 'I' AND NEW.status NOT IN ('P', 'H') THEN
      RAISE EXCEPTION 'Incoming messages can only be PENDING or HANDLED';
    END IF;
    IF NEW.direction = 'O' AND NEW.visibility = 'A' THEN
      RAISE EXCEPTION 'Outgoing messages cannot be archived';
    END IF;
  END IF;

  -- new message inserted
  IF TG_OP = 'INSERT' THEN
    -- don't update anything for a test message
    IF temba_contact_is_test(NEW.contact_id) THEN
      RETURN NULL;
    END IF;

    _new_label_type := temba_msg_determine_system_label(NEW);
    IF _new_label_type IS NOT NULL THEN
      PERFORM temba_insert_system_label(NEW.org_id, _new_label_type, 1);
    END IF;

  -- existing message updated
  ELSIF TG_OP = 'UPDATE' THEN
    _old_label_type := temba_msg_determine_system_label(OLD);
    _new_label_type := temba_msg_determine_system_label(NEW);

    IF _old_label_type IS DISTINCT FROM _new_label_type THEN
      -- don't update anything for a test message
      IF temba_contact_is_test(NEW.contact_id) THEN
        RETURN NULL;
      END IF;

      IF _old_label_type IS NOT NULL THEN
        PERFORM temba_insert_system_label(OLD.org_id, _old_label_type, -1);
      END IF;
      IF _new_label_type IS NOT NULL THEN
        PERFORM temba_insert_system_label(NEW.org_id, _new_label_type, 1);
      END IF;
    END IF;

    -- is being archived or deleted (i.e. no longer included for user labels)
    IF OLD.visibility = 'V' AND NEW.visibility != 'V' THEN
      PERFORM temba_insert_message_label_counts(NEW.id, -1);
    END IF;

    -- is being restored (i.e. now included for user labels)
    IF OLD.visibility != 'V' AND NEW.visibility = 'V' THEN
      PERFORM temba_insert_message_label_counts(NEW.id, 1);
    END IF;

  -- existing message deleted
  ELSIF TG_OP = 'DELETE' THEN
    -- don't update anything for a test message
    IF temba_contact_is_test(OLD.contact_id) THEN
      RETURN NULL;
    END IF;

    _old_label_type := temba_msg_determine_system_label(OLD);

    IF _old_label_type IS NOT NULL THEN
      PERFORM temba_insert_system_label(OLD.org_id, _old_label_type, -1);
    END IF;

  -- all messages deleted
  ELSIF TG_OP = 'TRUNCATE' THEN
    PERFORM temba_reset_system_labels('{"I", "W", "A", "O", "S", "X"}');

  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Reset (i.e. zero-ize) system label counts of the given type across all orgs
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_reset_system_labels(_label_types CHAR(1)[]) RETURNS VOID AS $$
BEGIN
  DELETE FROM msgs_systemlabelcount WHERE label_type = ANY(_label_types);
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Utility function to return the appropriate from uuid
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_step_from_uuid(_row flows_flowstep) RETURNS UUID AS $$
BEGIN
  IF _row.rule_uuid IS NOT NULL THEN
    RETURN UUID(_row.rule_uuid);
  END IF;

  RETURN UUID(_row.step_uuid);
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Manages keeping track of the # of messages sent and received by a channel
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_update_channelcount() RETURNS TRIGGER AS $$
DECLARE
  is_test boolean;
BEGIN
  -- Message being updated
  IF TG_OP = 'INSERT' THEN
    -- Return if there is no channel on this message
    IF NEW.channel_id IS NULL THEN
      RETURN NULL;
    END IF;

    -- Find out if this is a test contact
    SELECT contacts_contact.is_test INTO STRICT is_test FROM contacts_contact WHERE id=NEW.contact_id;

    -- Return if it is
    IF is_test THEN
      RETURN NULL;
    END IF;

    -- If this is an incoming message, without message type, then increment that count
    IF NEW.direction = 'I' THEN
      -- This is a voice message, increment that count
      IF NEW.msg_type = 'V' THEN
        PERFORM temba_insert_channelcount(NEW.channel_id, 'IV', NEW.created_on::date, 1);
      -- Otherwise, this is a normal message
      ELSE
        PERFORM temba_insert_channelcount(NEW.channel_id, 'IM', NEW.created_on::date, 1);
      END IF;

    -- This is an outgoing message
    ELSIF NEW.direction = 'O' THEN
      -- This is a voice message, increment that count
      IF NEW.msg_type = 'V' THEN
        PERFORM temba_insert_channelcount(NEW.channel_id, 'OV', NEW.created_on::date, 1);
      -- Otherwise, this is a normal message
      ELSE
        PERFORM temba_insert_channelcount(NEW.channel_id, 'OM', NEW.created_on::date, 1);
      END IF;

    END IF;

  -- Assert that updates aren't happening that we don't approve of
  ELSIF TG_OP = 'UPDATE' THEN
    -- If the direction is changing, blow up
    IF NEW.direction <> OLD.direction THEN
      RAISE EXCEPTION 'Cannot change direction on messages';
    END IF;

    -- Cannot move from IVR to Text, or IVR to Text
    IF (OLD.msg_type <> 'V' AND NEW.msg_type = 'V') OR (OLD.msg_type = 'V' AND NEW.msg_type <> 'V') THEN
      RAISE EXCEPTION 'Cannot change a message from voice to something else or vice versa';
    END IF;

    -- Cannot change created_on
    IF NEW.created_on <> OLD.created_on THEN
      RAISE EXCEPTION 'Cannot change created_on on messages';
    END IF;

  -- Table being cleared, reset all counts
  ELSIF TG_OP = 'TRUNCATE' THEN
    DELETE FROM channels_channel WHERE count_type IN ('IV', 'IM', 'OV', 'OM');
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Manages keeping track of the # of messages in our channel log
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_update_channellog_count() RETURNS TRIGGER AS $$
BEGIN
  -- ChannelLog being added
  IF TG_OP = 'INSERT' THEN
    -- Error, increment our error count
    IF NEW.is_error THEN
      PERFORM temba_insert_channelcount(NEW.channel_id, 'LE', NULL::date, 1);
    -- Success, increment that count instead
    ELSE
      PERFORM temba_insert_channelcount(NEW.channel_id, 'LS', NULL::date, 1);
    END IF;

  -- Updating is_error is forbidden
  ELSIF TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION 'Cannot update is_error or channel_id on ChannelLog events';

  -- Deleting, decrement our count
  ELSIF TG_OP = 'DELETE' THEN
    -- Error, decrement our error count
    IF OLD.is_error THEN
      PERFORM temba_insert_channelcount(OLD.channel_id, 'LE', NULL::date, -1);
    -- Success, decrement that count instead
    ELSE
      PERFORM temba_insert_channelcount(OLD.channel_id, 'LS', NULL::date, -1);
    END IF;

  -- Table being cleared, reset all counts
  ELSIF TG_OP = 'TRUNCATE' THEN
    DELETE FROM channels_channel WHERE count_type IN ('LE', 'LS');
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Keeps track of our flowpathcounts as steps are updated
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_update_flowpathcount() RETURNS TRIGGER AS $$
DECLARE flow_id int;
BEGIN

  IF TG_OP = 'TRUNCATE' THEN
    -- FlowStep table being cleared, reset all counts
    DELETE FROM flows_flownodecount;
    DELETE FROM flows_flowpathcount;

  -- FlowStep being deleted
  ELSIF TG_OP = 'DELETE' THEN

    -- ignore if test contact
    IF temba_contact_is_test(OLD.contact_id) THEN
      RETURN NULL;
    END IF;

    flow_id = temba_flow_for_run(OLD.run_id);

    IF OLD.left_on IS NULL THEN
      PERFORM temba_insert_flownodecount(flow_id, UUID(OLD.step_uuid), -1);
    ELSE
      PERFORM temba_insert_flowpathcount(flow_id, temba_step_from_uuid(OLD), UUID(OLD.next_uuid), OLD.left_on, -1);
    END IF;

  -- FlowStep being added or left_on field updated
  ELSIF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN

    -- ignore if test contact
    IF temba_contact_is_test(NEW.contact_id) THEN
      RETURN NULL;
    END IF;

    flow_id = temba_flow_for_run(NEW.run_id);

    IF NEW.left_on IS NULL THEN
      PERFORM temba_insert_flownodecount(flow_id, UUID(NEW.step_uuid), 1);
    ELSE
      PERFORM temba_insert_flowpathcount(flow_id, temba_step_from_uuid(NEW), UUID(NEW.next_uuid), NEW.left_on, 1);
    END IF;

    IF TG_OP = 'UPDATE' THEN
      IF OLD.left_on IS NULL THEN
        PERFORM temba_insert_flownodecount(flow_id, UUID(OLD.step_uuid), -1);
      ELSE
        PERFORM temba_insert_flowpathcount(flow_id, temba_step_from_uuid(OLD), UUID(OLD.next_uuid), OLD.left_on, -1);
      END IF;
    END IF;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Increments or decrements our counts for each exit type
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_update_flowruncount() RETURNS TRIGGER AS $$
BEGIN
  -- Table being cleared, reset all counts
  IF TG_OP = 'TRUNCATE' THEN
    TRUNCATE flows_flowruncounts;
    RETURN NULL;
  END IF;

  -- FlowRun being added
  IF TG_OP = 'INSERT' THEN
     -- Is this a test contact, ignore
     IF temba_contact_is_test(NEW.contact_id) THEN
       RETURN NULL;
     END IF;

    -- Increment appropriate type
    PERFORM temba_insert_flowruncount(NEW.flow_id, NEW.exit_type, 1);

  -- FlowRun being removed
  ELSIF TG_OP = 'DELETE' THEN
     -- Is this a test contact, ignore
     IF temba_contact_is_test(OLD.contact_id) THEN
       RETURN NULL;
     END IF;

    PERFORM temba_insert_flowruncount(OLD.flow_id, OLD.exit_type, -1);

  -- Updating exit type
  ELSIF TG_OP = 'UPDATE' THEN
     -- Is this a test contact, ignore
     IF temba_contact_is_test(NEW.contact_id) THEN
       RETURN NULL;
     END IF;

    PERFORM temba_insert_flowruncount(OLD.flow_id, OLD.exit_type, -1);
    PERFORM temba_insert_flowruncount(NEW.flow_id, NEW.exit_type, 1);
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------------------
-- Updates our topup credits for the topup being assigned to the Msg
----------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_update_topupcredits() RETURNS TRIGGER AS $$
BEGIN
  -- Msg is being created
  IF TG_OP = 'INSERT' THEN
    -- If we have a topup, increment our # of used credits
    IF NEW.topup_id IS NOT NULL THEN
      PERFORM temba_insert_topupcredits(NEW.topup_id, 1);
    END IF;

  -- Msg is being updated
  ELSIF TG_OP = 'UPDATE' THEN
    -- If the topup has changed
    IF NEW.topup_id IS DISTINCT FROM OLD.topup_id THEN
      -- If our old topup wasn't null then decrement our used credits on it
      IF OLD.topup_id IS NOT NULL THEN
        PERFORM temba_insert_topupcredits(OLD.topup_id, -1);
      END IF;

      -- if our new topup isn't null, then increment our used credits on it
      IF NEW.topup_id IS NOT NULL THEN
        PERFORM temba_insert_topupcredits(NEW.topup_id, 1);
      END IF;
    END IF;

  -- Msg is being deleted
  ELSIF TG_OP = 'DELETE' THEN
    -- Remove a used credit if this Msg had one assigned
    IF OLD.topup_id IS NOT NULL THEN
      PERFORM temba_insert_topupcredits(OLD.topup_id, -1);
    END IF;
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------------------
-- Updates our topup credits for the topup being assigned to a Debit
----------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION temba_update_topupcredits_for_debit() RETURNS TRIGGER AS $$
BEGIN
  -- Debit is being created
  IF TG_OP = 'INSERT' THEN
    -- If we are an allocation and have a topup, increment our # of used credits
    IF NEW.topup_id IS NOT NULL AND NEW.debit_type = 'A' THEN
      PERFORM temba_insert_topupcredits(NEW.topup_id, NEW.amount);
    END IF;

  -- Debit is being updated
  ELSIF TG_OP = 'UPDATE' THEN
    -- If the topup has changed
    IF NEW.topup_id IS DISTINCT FROM OLD.topup_id AND NEW.debit_type = 'A' THEN
      -- If our old topup wasn't null then decrement our used credits on it
      IF OLD.topup_id IS NOT NULL THEN
        PERFORM temba_insert_topupcredits(OLD.topup_id, OLD.amount);
      END IF;

      -- if our new topup isn't null, then increment our used credits on it
      IF NEW.topup_id IS NOT NULL THEN
        PERFORM temba_insert_topupcredits(NEW.topup_id, NEW.amount);
      END IF;
    END IF;

  -- Debit is being deleted
  ELSIF TG_OP = 'DELETE' THEN
    -- Remove a used credit if this Debit had one assigned
    IF OLD.topup_id IS NOT NULL AND OLD.debit_type = 'A' THEN
      PERFORM temba_insert_topupcredits(OLD.topup_id, OLD.amount);
    END IF;
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Trigger procedure to update contact system groups on column changes
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_contact_system_groups() RETURNS TRIGGER AS $$
BEGIN
  -- new contact added
  IF TG_OP = 'INSERT' AND NEW.is_active AND NOT NEW.is_test THEN
    IF NEW.is_blocked THEN
      PERFORM contact_toggle_system_group(NEW, 'B', true);
    END IF;

    IF NEW.is_stopped THEN
      PERFORM contact_toggle_system_group(NEW, 'S', true);
    END IF;

    IF NOT NEW.is_stopped AND NOT NEW.is_blocked THEN
      PERFORM contact_toggle_system_group(NEW, 'A', true);
    END IF;
  END IF;

  -- existing contact updated
  IF TG_OP = 'UPDATE' AND NOT NEW.is_test THEN
    -- do nothing for inactive contacts
    IF NOT OLD.is_active AND NOT NEW.is_active THEN
      RETURN NULL;
    END IF;

    -- is being blocked
    IF NOT OLD.is_blocked AND NEW.is_blocked THEN
      PERFORM contact_toggle_system_group(NEW, 'B', true);
      PERFORM contact_toggle_system_group(NEW, 'A', false);
    END IF;

    -- is being unblocked
    IF OLD.is_blocked AND NOT NEW.is_blocked THEN
      PERFORM contact_toggle_system_group(NEW, 'B', false);
      IF NOT NEW.is_stopped THEN
        PERFORM contact_toggle_system_group(NEW, 'A', true);
      END IF;
    END IF;

    -- they stopped themselves
    IF NOT OLD.is_stopped AND NEW.is_stopped THEN
      PERFORM contact_toggle_system_group(NEW, 'S', true);
      PERFORM contact_toggle_system_group(NEW, 'A', false);
    END IF;

    -- they opted back in
    IF OLD.is_stopped AND NOT NEW.is_stopped THEN
    PERFORM contact_toggle_system_group(NEW, 'S', false);
      IF NOT NEW.is_blocked THEN
        PERFORM contact_toggle_system_group(NEW, 'A', true);
      END IF;
    END IF;

    -- is being released
    IF OLD.is_active AND NOT NEW.is_active THEN
      PERFORM contact_toggle_system_group(NEW, 'A', false);
      PERFORM contact_toggle_system_group(NEW, 'B', false);
      PERFORM contact_toggle_system_group(NEW, 'S', false);
    END IF;

    -- is being unreleased
    IF NOT OLD.is_active AND NEW.is_active THEN
      IF NEW.is_blocked THEN
        PERFORM contact_toggle_system_group(NEW, 'B', true);
      END IF;

      IF NEW.is_stopped THEN
        PERFORM contact_toggle_system_group(NEW, 'S', true);
      END IF;

      IF NOT NEW.is_stopped AND NOT NEW.is_blocked THEN
        PERFORM contact_toggle_system_group(NEW, 'A', true);
      END IF;
    END IF;

  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

----------------------------------------------------------------------
-- Trigger procedure to update group count
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_group_count() RETURNS TRIGGER AS $$
DECLARE
  is_test BOOLEAN;
BEGIN
  -- contact being added to group
  IF TG_OP = 'INSERT' THEN
    -- is this a test contact
    SELECT contacts_contact.is_test INTO STRICT is_test FROM contacts_contact WHERE id = NEW.contact_id;

    IF NOT is_test THEN
      INSERT INTO contacts_contactgroupcount("group_id", "count", "is_squashed")
      VALUES(NEW.contactgroup_id, 1, FALSE);
    END IF;

  -- contact being removed from a group
  ELSIF TG_OP = 'DELETE' THEN
    -- is this a test contact
    SELECT contacts_contact.is_test INTO STRICT is_test FROM contacts_contact WHERE id = OLD.contact_id;

    IF NOT is_test THEN
      INSERT INTO contacts_contactgroupcount("group_id", "count", "is_squashed")
      VALUES(OLD.contactgroup_id, -1, FALSE);
    END IF;

  -- table being cleared, clear our counts
  ELSIF TG_OP = 'TRUNCATE' THEN
    TRUNCATE contacts_contactgroupcount;
  END IF;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

