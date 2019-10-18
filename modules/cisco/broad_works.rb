# frozen_string_literal: true
# encoding: ASCII-8BIT

module Cisco; end

::Orchestrator::DependencyManager.load('Cisco::BroadSoft::BroadWorks', :model, :force)

class Cisco::BroadWorks
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    include ::Orchestrator::Security

    descriptive_name 'Cisco BroadWorks Call Center Management'
    generic_name :CallCenter

    # Discovery Information
    implements :service
    keepalive false # HTTP keepalive

    default_settings({
        username: :cisco,
        password: :cisco,
        events_domain: 'xsi-events.endpoint.com',
        proxy: 'http://proxy.com:8080',
        callcenters: {"phone_number@domain.com" => "Other Matters"}
    })

    def on_load
        HTTPI.log = false
        @terminated = false

        last_known = setting(:last_known_stats) || {
          stats: {},
          longest_wait: 0,
          longest_talk: 0
        }
        @saved_stats = last_known[:stats]
        @saved_longest_wait = last_known[:longest_wait]
        @saved_longest_talk = last_known[:longest_talk]

        on_update
    end

    def on_update
        @username = setting(:username)
        @password = setting(:password)
        @domain = setting(:events_domain)
        @proxy = setting(:proxy) || ENV["HTTPS_PROXY"] || ENV["https_proxy"]
        @callcenters = setting(:callcenters) || {}
        self[:achievements] = setting(:achievements) || []
        self[:news] = setting(:news) || []

        # "sub_id" => "callcenter id"
        @subscription_lookup ||= {}
        # "call_id" => {user: user_id, center: "callcenter id", time: 435643}
        @call_tracking ||= {}

        @queued_calls ||= {}
        @abandoned_calls ||= {}
        @calls_taken ||= {}
        @talk_time ||= {}
        @call_tracking ||= {}

        @poll_sched&.cancel
        @reset_sched&.cancel

        # Every 2 min
        @poll_sched = schedule.every(120_000) do
            @callcenters.each_key { |id| get_call_count(id) }
            check_call_state
        end

        # Every day at 5am
        @reset_sched = schedule.cron("0 5 * * *") { reset_stats }

        connect
    end

    def set_achievements(achievements)
      achievements ||= []
      define_setting(:achievements, achievements)
      self[:achievements] = achievements
    end

    def set_news(news)
      news ||= []
      define_setting(:news, news)
      self[:news] = news
    end

    def reset_stats
        # "callcenter id" => count
        @queued_calls = {}
        @abandoned_calls = {}

        # "callcenter id" => Array(wait_times)
        @calls_taken = {}

        # "callcenter id" => Array(talk_times)
        @talk_time = {}

        # We reset the call tracker
        # Probably not needed but might accumulate calls over time
        @call_tracking = {}

        @saved_stats = {}
        @saved_longest_wait = 0
        @saved_longest_talk = 0
        define_setting(:last_known_stats, {
            stats: {},
            longest_wait: 0,
            longest_talk: 0
        })
        true
    end

    def on_unload
        @terminated = true
        @bw.close_channel
    end

    def connect
        return if @terminated

        @bw.close_channel if @bw
        reactor = self.thread
        callcenters = @callcenters

        @bw = Cisco::BroadSoft::BroadWorks.new(@domain, @username, @password, proxy: @proxy, logger: logger)
        bw = @bw
        Thread.new do
            bw.open_channel do |event|
                reactor.schedule { process_event(event) }
            end
        end
        nil
    end

    SHOULD_UPDATE = Set.new(['ACDCallAddedEvent', 'ACDCallAbandonedEvent', 'ACDCallReleasedEvent', 'ACDCallStrandedEvent', 'ACDCallAnsweredByAgentEvent', 'CallReleasedEvent'])

    def process_event(event)
        # Check if the connection was terminated
        if event.nil?
            logger.debug { "Connection closed! Reconnecting: #{!@terminated}" }
            if !@terminated
                schedule.in(1000) do
                    @bw = nil
                    connect
                end
            end
            return
        end

        # Lookup the callcenter in question
        call_center_id = @subscription_lookup[event[:subscription_id]]
        logger.debug { "processing event #{event[:event_name]}" }

        # Otherwise process the event
        case event[:event_name]
        when 'new_channel'
            monitor_callcenters
        when 'ACDCallAddedEvent'
            count = @queued_calls[call_center_id]
            @queued_calls[call_center_id] = count.to_i + 1
        when 'ACDCallAbandonedEvent'
            count = @abandoned_calls[call_center_id]
            @abandoned_calls[call_center_id] = count.to_i + 1

            count = @queued_calls[call_center_id].to_i - 1
            @queued_calls[call_center_id] = count < 0 ? 0 : count
        when 'ACDCallStrandedEvent'
            # Not entirely sure when this happens
            count = @queued_calls[call_center_id].to_i - 1
            @queued_calls[call_center_id] = count < 0 ? 0 : count
        when 'ACDCallAnsweredByAgentEvent'
            # TODO:: Call answered by "0278143573@det.nsw.edu.au"
            # Possibly we can monitor the time this conversion goes for?
            count = @queued_calls[call_center_id].to_i - 1
            @queued_calls[call_center_id] = count < 0 ? 0 : count

            # Extract wait time...
            event_data = event[:event_data]
            start_time = event_data.xpath("//addTime").inner_text.to_i
            answered_time = event_data.xpath("//removeTime").inner_text.to_i
            wait_time = answered_time - start_time

            wait_times = @calls_taken[call_center_id] || []
            wait_times << wait_time
            @calls_taken[call_center_id] = wait_times
        when 'ACDWhisperStartedEvent'
            # The agent has decided to accept the call.
            event_data = event[:event_data]
            user_id = event_data.xpath("//answeringUserId").inner_text
            call_id = event_data.xpath("//answeringCallId").inner_text

            @call_tracking[call_id] = {
                user: user_id,
                center: call_center_id,
                time: Time.now.to_i
            }

            bw = @bw
            logger.info { "tracking call #{call_id} handled by #{user_id}" }
            task { bw.get_user_events(user_id, "Basic Call") }
        when 'CallReleasedEvent', 'ACDCallReleasedEvent'
            event_data = event[:event_data]
            call_id = event_data.xpath("//callId").inner_text
            call_details = @call_tracking.delete call_id

            logger.info { "call #{call_id} ended, was tracked: #{!!call_details}" }

            if call_details
                call_center_id = call_details[:center]

                answered_time = event_data.xpath("//answerTime").inner_text.to_i
                released_time = event_data.xpath("//releaseTime").inner_text.to_i

                talk_time = released_time - answered_time
                talk_times = @talk_time[call_center_id] || []
                talk_times << talk_time
                @talk_time[call_center_id] = talk_times
            end
        else
            logger.info { "ignoring event #{event[:event_name]}" }
        end

        if SHOULD_UPDATE.include?(event[:event_name])
            update_stats
        end
    end

    def monitor_callcenters
        # Reset the lookups
        @subscription_lookup = {}
        @queued_calls = {}

        bw = @bw
        reactor = self.thread
        @callcenters.each do |id, name|
            # Run the request on the thread pool
            retries = 0
            begin
                task {
                    sub_id = bw.get_user_events(id)

                    # Ensure the mapping is maintained
                    reactor.schedule do
                        if bw.channel_open
                            @subscription_lookup[sub_id] = id
                            get_call_count(id)
                        end
                    end
                }.value

                break unless bw.channel_open
            rescue => e
                logger.error "monitoring callcenter #{name}\n#{e.message}"
                break unless bw.channel_open
                retries += 1
                retry unless retries > 3
            end
        end

        user_ids = []
        @call_tracking.each do |key, value|
            user_ids << value[:user]
        end
        return if user_ids.empty?
        begin
            task {
                user_ids.each { |id| bw.get_user_events(id, "Basic Call") }
            }.value
        rescue => e
            logger.error "monitoring users\n#{e.message}"
        end
    end

    def get_proxy_details
        if @proxy
            proxy = URI.parse @proxy
            {
                host: proxy.host,
                port: proxy.port
            }
        end
    end

    # Non-event related calls
    def get_call_count(call_center_id)
        get("/com.broadsoft.xsi-actions/v2.0/callcenter/#{call_center_id}/calls",
          name: "call_center_#{call_center_id}_calls",
          proxy: get_proxy_details,
          headers: {Authorization: [@username, @password]}
        ) do |data, resolve, command|
            if data.status == 200
                xml = Nokogiri::XML(data.body)
                xml.remove_namespaces!
                @queued_calls[call_center_id] = xml.xpath("//queueEntry").length
            else
                logger.warn "failed to retrieve active calls for #{@callcenters[call_center_id]} - response code: #{data&.status}"
            end
            :success
        end
    end

    def update_stats
        queues = {}
        total_abandoned = 0
        all_calls = []
        all_times = []

        # Summarise current calls
        num_on_call = {}
        @call_tracking.each do |call_id, details|
            center_id = details[:center]
            count = num_on_call[center_id] || 0
            count += 1
            num_on_call[center_id] = count
        end

        # Build a summary of each DC
        @callcenters.each do |id, name|
            calls = Array(@calls_taken[id])
            abandoned = @abandoned_calls[id].to_i
            # total_abandoned += abandoned
            all_calls.concat calls

            times = Array(@talk_time[id])
            all_times.concat times

            details = {
                queue_length: @queued_calls[id].to_i,
                abandoned: abandoned,
                total_calls: calls.size,
                # Time in milliseconds
                average_wait: (calls.reduce(:+) || 0) / [1, calls.size].max,
                max_wait: calls.max.to_i,

                average_talk: (times.reduce(:+) || 0) / [1, times.size].max,
                on_calls: num_on_call[id].to_i
            }

            queues[name] = details
        end

        # saved details
        @saved_stats.each do |name, details|
          queue = queues[name]
          next unless queue

          # the .to_i handles nil cases
          total_calls = details[:total_calls].to_i + queue[:total_calls].to_i
          if details[:average_wait]
            # the .to_i handles nil cases
            avg = (queue[:average_wait].to_i * queue[:total_calls].to_i + details[:average_wait].to_i * details[:total_calls].to_i) / total_calls
            queue[:average_wait] = avg
          end
          if details[:average_talk]
            avg = (queue[:average_talk].to_i * queue[:total_calls].to_i + details[:average_talk].to_i * details[:total_calls].to_i) / total_calls
            queue[:average_wait] = avg
          end

          queue[:abandoned] += details[:abandoned] || 0
          queue[:total_calls] = total_calls
          queue[:max_wait] = [queue[:max_wait], details[:max_wait] || 0].max
        end

        # calculate abandoned
        queues.each do |name, details|
          total_abandoned += details[:abandoned] || 0
        end

        # Expose the state
        self[:queues] = queues
        self[:total_abandoned] = total_abandoned

        # TODO:: confirm if this is longest in the day or in the current queue?
        self[:longest_wait] = [all_calls.max.to_i, @saved_longest_wait || 0].max
        self[:longest_talk] = [all_times.max.to_i, @saved_longest_talk || 0].max

        # save the details in the database
        define_setting(:last_known_stats, {
            stats: queues,
            longest_wait: self[:longest_wait],
            longest_talk: self[:longest_talk]
        })
        true
    end

    # Ensure the calls that are active are still active:
    def check_call_state
        # This doesn't update stats like average wait times as would only typically occur
        # when someone hangs up really fast as the events in the system are delays by about 10 seconds
        @call_tracking.each do |call_id, details|
            current_calls(details[:user]).then do |call_ids|
                if !call_ids.include?(call_id)
                    count = details[:check_failed].to_i
                    count += 1
                    if count == 2
                        logger.debug { "call tracking failed for #{call_id} with user #{details[:user]}" }
                        @call_tracking.delete(call_id)
                    else
                        details[:check_failed] = count
                    end
                end
            end
        end
    end

    def current_calls(user_id)
        # i.e. an event isn't missed: /com.broadsoft.xsi-actions/v2.0/user/<userid>/calls
        # Returns an object with multiple <callId>callhalf-722:0</callId>
        get("/com.broadsoft.xsi-actions/v2.0/user/#{user_id}/calls",
          name: "current_#{user_id}_calls",
          proxy: get_proxy_details,
          headers: {Authorization: [@username, @password]}
        ) do |data, resolve, command|
            if data.status == 200
                xml = Nokogiri::XML(data.body)
                xml.remove_namespaces!
                xml.xpath("//callId").map(&:inner_text)
            else
                logger.warn "failed to retrieve active calls for user #{user_id} - response code: #{data&.status}"
                :abort
            end
        end
    end
end
