require 'slack-ruby-client'
require 'slack/real_time/concurrency/libuv'
require 'microsoft/office'

class Aca::SlackBooking
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder
    include ::Orchestrator::Security


    descriptive_name 'Slack Booking'
    generic_name :Slack
    implements :logic

    def on_load
        on_update
    end

    def on_update
        on_unload   
        create_websocket
        self[:channel] = setting(:channel) || :concierge
    end

    def on_unload
        @client.stop! if @client && @client.started?
        @client = nil
    end
    
    def post_message(text)
        @client.web_client.chat_postMessage channel: setting(:channel), text: text, username: 'Room Bot'
    end

    # Message coming in from Slack API
    def on_message(data)
        STDERR.puts "GOT MESSAGE"
        STDERR.puts data.inspect
        logger.info data
        logger.info "Current command is #{self['current_command']}"
        logger.info "Current command is nil? #{self['current_command'].nil?}"
        STDERR.flush
        if data.key?("subtype") && data['subtype'] == 'bot_message'
            logger.info "Got a bot message, stopping."
            return
        else
            if self['current_command'].nil?
                logger.info "Matching against lines"
                matched_lines = [
                    "free room",
                    "free space",
                    "available room",
                    "rooms are free"
                ]
                if matched_lines.any? { |s| data['text'].include?(s) }
                    self['current_command'] = 'duration'
                    post_message("How long do you need it for (in minutes)?")
                    return
                end
            end

            if self['current_command'] == 'duration'
                self['duration'] = data['text'].to_i
                post_message("Let me check that for you...")

                rooms = Orchestrator::ControlSystem.all.to_a
                room_emails = rooms.map {|r| r.email }.compact

                all_bookings = @office.get_bookings_by_user(
                    user_id: room_emails,
                    available_from: Time.now,
                    available_to: Time.now + self['duration'].minutes,
                    start_param: Time.now,
                    end_param: Time.now + self['duration'].minutes,
                    bulk: true
                )
                post_message("The following rooms are available:")
                count = 0
                rooms.each_with_index do |room, i|
                    if room.bookable && room.name.include?("SYD") && all_bookings[room.email][:available] 
                        post_message("#{count + 1}. #{room.name}")
                        count += 1
                        self['available_rooms'].push(room)
                    end
                end
                post_message("If you would like to book one, please specify its number now.")
                self['current_command'] = 'selection'
                return
            end

            if self['current_command'] == 'selection'
                self['selection'] = data['text'].to_i - 1
                self['selected_room'] = self['available_rooms'][self['selection']].email
                post_message("You have selected #{self['available_rooms'][self['selection']].name}")
                post_message("Who would you like to invite to this room? (separated by a space)")
                self['current_command'] = 'emails'
                return
            end

            if self['current_command'] == 'emails'
                # WOAH HACKY
                emails = data['text'].split("<mailto:")[1..-1].join("").split("|").join(" ").gsub!(">"," ").split(" ").uniq 
                self['emails'] = emails.map {|e| {email: e, name: e} }
                self['current_command'] = 'confirm'
                post_message("Would you like me to book the following room? (yes / no)")
                post_message("#{self['available_rooms'][self['selection']].name} for #{self['duration']} minutes with #{emails.join(" ")}")
                return
            end

            if self['current_command'] == 'confirm'
                if data['text'].downcase == 'yes' || data['text'].downcase == 'y'
                    create_params = {
                        room_id: self['selected_room'],
                        start_param: Time.now,
                        end_param: Time.now + self['duration'].minutes,
                        subject: "Slack Booking",
                        description: "",
                        current_user: nil,
                        attendees: self['emails'],
                        recurrence: nil,
                        recurrence_end: nil,
                        timezone: ENV['TIMEZONE'] || 'UTC'
                    }

                    # if room.settings.key?('direct_book') && room.settings['direct_book'] 
                    #     create_params[:endpoint_override] = room.email
                    # end

                    @office.create_booking(create_params)
                    post_message("That's booked! Enjoy your meeting.")
                end
            end
        end
    end

    protected

    # Create a realtime WS connection to the Slack servers
    def create_websocket

        @office = ::Microsoft::Office.new({
            client_id: ENV['OFFICE_CLIENT_ID'],
            client_secret: ( ENV["OFFICE_CLIENT_SECRET"] || "M6o]=6{Qi>*:?+_>|%}#_s[*/}$1}^N[.=D&>Lg--}!+{=&.*{/:|J_|%.{="),
            app_site: ENV["OFFICE_SITE"] || "https://login.microsoftonline.com",
            app_token_url: ENV["OFFICE_TOKEN_URL"],
            app_scope: ENV['OFFICE_SCOPE'] || "https://graph.microsoft.com/.default",
            graph_domain: ENV['GRAPH_DOMAIN'] || "https://graph.microsoft.com",
            service_account_email: ENV['OFFICE_ACCOUNT_EMAIL'],
            service_account_password: ENV['OFFICE_ACCOUNT_PASSWORD'],
            internet_proxy: ENV['INTERNET_PROXY']
        })

        self['available_rooms'] = []
        self['current_command'] = nil
        self['selected_room'] = nil
        self['duration'] = nil
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
            logger.info e.message
            logger.info e.backtrace.inspect  
	    end

        end
        # Start the client
	    @client.start!
    end

end
