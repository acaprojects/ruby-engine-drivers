require 'slack-ruby-client'
require 'slack/real_time/concurrency/libuv'

class Aca::Slack
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    include ::Orchestrator::Security


    descriptive_name 'Slack Connector'
    generic_name :Slack
    implements :logic

    def on_load
        on_update
    end

    def on_update
        on_unload   
        create_websocket
        self[:building] = setting(:building) || :barangaroo
        self[:channel] = setting(:channel) || :concierge
    end

    def on_unload
        @client.stop! if @client && @client.started?
        @client = nil
    end
    
    # Message coming in from Slack API
    def on_message(data)
        # This should always be set as all messages from the slack client should be replies
        if data.thread_ts || data.ts 
            user_id = get_user_id(data.thread_ts) || get_user_id(data.ts)

        # Assuming the user exists (it should always as they must send the first message)_
	    if !user_id.nil?
            	self["last_message_#{user_id}"] = data
	    end
        end
    end

    # Message from the frontend
    def send_message(message_text)
        user = current_user
        thread_id = get_thread_id(user)

        # A thread exists meaning this is not the user's first message
        if thread_id
            # Post to the slack channel using the thread ID
            message = @client.web_client.chat_postMessage channel: setting(:channel), text: message_text, username: current_user.email, thread_ts: thread_id

        # This is the user's first message
        else
            # Post to the slack channel using the thread ID
            message = @client.web_client.chat_postMessage channel: setting(:channel), text: message_text, username: current_user.email        
            
            # Store thread id
            thread_id = message['message']['ts']
            User.bucket.set("slack-thread-#{user.id}-#{setting(:building)}", thread_id)
            User.bucket.set("slack-user-#{thread_id}", user.id)
	        on_message(message.message)
        end
        user.last_message_sent = Time.now.to_i * 1000
        user.save!
    end

    def get_historic_messages
        # Grab the thread ID of the currently logged in user
        user = current_user
        thread_id = get_thread_id(user)

        # If it exists, they've sent messages before
        if thread_id

            # We can't use the client for this for some reason that I can't remember
            slack_api = UV::HttpEndpoint.new("https://slack.com")
            req = {
                token: @client.token,
                channel: setting(:channel),
                thread_ts: thread_id
            }
            response = slack_api.post(path: 'https://slack.com/api/channels.replies', body: req).value
            
            messages = JSON.parse(response.body)['messages']
            
            {
                last_sent: user.last_message_sent,
                last_read: user.last_message_read,
                thread_id: thread_id,
                messages: messages
            }
        # Otherwise just send back nothing
        else
            {
                last_sent: user.last_message_sent,
                last_read: user.last_message_read,
                thread_id: nil,
                messages: []
            }
        end
    end


    protected

    def get_thread_id(user)
        User.bucket.get("slack-thread-#{user.id}-#{setting(:building)}", quiet: true)
    end

    def get_user_id(thread_id)
        User.bucket.get("slack-user-#{thread_id}", quiet: true)
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
        @client.on :message do |data|
	    begin
            #@client.typing channel: data.channel
            on_message(data)
	    rescue Exception => e
	    end

        end
        # Start the client
	    @client.start!
    end

end
