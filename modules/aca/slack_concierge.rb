require 'slack-ruby-client'
require 'slack/real_time/concurrency/libuv'

class Aca::SlackConcierge
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    include ::Orchestrator::Security


    descriptive_name 'Slack Concierge Connector'
    generic_name :Slack
    implements :logic

    def log(msg)
        logger.info msg
        STDERR.puts msg
        STDERR.flush
    end

    def on_load
        on_update
    end

    def on_update
        on_unload   
        create_websocket
        @threads = []
        self[:building] = setting(:building) || :barangaroo
        self[:`] = setting(:channel) || :concierge
    end

    def on_unload
        @client.stop! if @client && @client.started?
        @client = nil
    end

    # Message from the concierge frontend
    def send_message(message_text, thread_id)
        message = @client.web_client.chat_postMessage channel: setting(:channel), text: message_text, thread_ts: thread_id, username: 'Concierge'
    end

    def update_last_message_read(thread_id)
        @threads.each_with_index do |thread, i|
            if thread['ts'] == thread_id
                message_obj = @threads[i].dup
                message_obj['last_read'] = Time.now.to_i * 1000
                @threads[i] = message_obj
                self["threads"] = @threads.deep_dup
            end
        end
        user = find_user(thread_id)
        user = User.find(User.bucket.get("slack-user-#{thread_id}", quiet: true)) if user.nil?
        user.last_message_read = Time.now.to_i * 1000
        user.save!
    end


    def get_threads
        # Get the messages from far back (when over 1000 we need to paginate)
        page_count = 1
        all_messages = @client.web_client.channels_history({channel:setting(:channel), count: 1000})['messages']

        while (all_messages.length) == (1000 * page_count)
            page_count += 1
            all_messages += @client.web_client.channels_history({channel: setting(:channel), latest: all_messages.last['ts'], count: 1000})['messages']
        end

        # Delete messages that aren't threads ((either has no thread_ts OR thread_ts == ts) AND type == bot_message)
        messages = []
        all_messages.each do |message|
            if (!message.key?('thread_ts') || message['thread_ts'] == message['ts']) && message['subtype'] == 'bot_message'
                if message.key?('username')
                    user = find_user(message['username'])
                    if !user.nil? && !User.bucket.get("slack-user-#{message['ts']}", quiet: true).nil?
                        message['email'] = user.email
                        message['name'] = user.name
                        messages.push(message) 
                    end
                end
            end
        end

        # Output count as if this gets > 1000 we need to paginate

        # For every message, grab the user's details out of it
        messages.each_with_index{|message, i|   
            # If the message has a username associated (not a status message, etc)
            # Then grab the details and put it into the message
            if message.key?('username')
                user = find_user(message['username'])
                next if user.nil?
                messages[i]['email'] = user.email
                messages[i]['name'] = user.name
            end

            # If the user sending the message exists (this should essentially always be the case)
            if !user.nil?
                messages[i]['last_sent'] = user.last_message_sent
                messages[i]['last_read'] = user.last_message_read
            else
                messages[i]['last_sent'] = nil
                messages[i]['last_read'] = nil
            end

            # update_last_message_read(messages[i]['email'])
            messages[i]['replies'] = get_message(message['ts'])
        }

        # Bind the frontend to the messages
        @threads = messages
        self["threads"] = @threads.deep_dup
    end

    def get_message(thread_id)
        # Get the messages
        slack_api = UV::HttpEndpoint.new("https://slack.com")
        req = {
            token: @client.token,
            channel: setting(:channel),
            thread_ts: thread_id
        }
        response = slack_api.post(path: 'https://slack.com/api/channels.replies', body: req).value
        JSON.parse(response.body)['messages']
    end

    def get_thread(thread_id)
        # Get the messages
        slack_api = UV::HttpEndpoint.new("https://slack.com")
        req = {
            token: @client.token,
            channel: setting(:channel),
            thread_ts: thread_id
        }
        response = slack_api.post(path: 'https://slack.com/api/channels.replies', body: req).value
        messages = JSON.parse(response.body)['messages']
        self["thread_#{thread_id}"] = messages
        return nil
    end


    protected

    def find_user(email)
        authority_id = Authority.find_by_domain(ENV['EMAIL_DOMAIN']).id
        user = User.find_by_email(authority_id, email )
        if user.nil?
            authority_id = Authority.find_by_domain(ENV['STAFF_DOMAIN']).id
            user = User.find_by_email(authority_id, email )
        end
        user
    end

    # Create a realtime WS connection to the Slack servers
    def create_websocket

        # Set our token and other config options
        ::Slack.configure do |config|
            config.token = setting(:slack_api_token)
            config.logger = Logger.new(STDOUT)
            config.logger.level = Logger::INFO
            fail 'Missing slack api token setting!' unless config.token
        end

        # Use Libuv as our concurrency driver
        ::Slack::RealTime.configure do |config|
           config.concurrency = Slack::RealTime::Concurrency::Libuv
        end

        # Create the client and set the callback function when a message is received
        @client = ::Slack::RealTime::Client.new
        
        get_threads


        @client.on :message do |data|
             # Ensure that it is a bot_message or slack client reply
             if ['bot_message'].include?(data['subtype'])

                # If this is a reply (has a thread_ts field)
                if data.key?('thread_ts')
                    new_message = data.to_h
                    new_threads = @threads.deep_dup

                    # Loop through the array and add user data
                    new_threads.each_with_index do |thread, i|
                        # If the ID of the looped message equals the new message thread ID
                        if thread['ts'] == new_message['thread_ts']
                            new_message['email'] = new_message['username']
                            new_threads[i]['replies'].push(new_message)
                            new_threads[i]['latest_reply'] = new_message['ts']
                            self["thread_#{new_message['thread_ts']}"] = new_threads[i]['replies'].dup
                            break
                        end
                    end
                    @threads = new_threads
                    self["threads"] = new_threads.deep_dup
                else
                    new_message = data.to_h

                    if new_message['username'] != 'Concierge'
                        user = find_user(new_message['username'])
                        if user
                            new_message['last_read'] = user.last_message_read
                            new_message['last_sent'] = user.last_message_sent
                        end
                    end

                    new_message_copy = new_message.deep_dup
                    new_message['replies'] = [new_message_copy]

                    @threads = @threads.insert(0, new_message)
                    self["threads"] = @threads.deep_dup
                end    
            end                
            
        end

        @client.start!

    end
end
