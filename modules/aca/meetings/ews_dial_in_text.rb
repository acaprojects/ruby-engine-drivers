module Aca; end
module Aca::Meetings; end


load File.expand_path('./ews_appender.rb', File.dirname(__FILE__))
load File.expand_path('./webex_api.rb',    File.dirname(__FILE__))
RestClient.proxy = "http://10.0.10.27/"

require 'set'
require 'action_view'
require 'action_view/helpers'


class Aca::Meetings::EwsDialInText
    include ::Orchestrator::Constants
    # http://apidock.com/rails/ActionView/Helpers/DateHelper/distance_of_time_in_words
    include ::ActionView::Helpers::DateHelper

    descriptive_name 'ACA Room Booking Text Appender'
    generic_name :MeetingAppender
    implements :logic

    default_settings meeting_rooms: {
            'room@org.com' => 'system_id'
        },
        config: ['https://org.com/EWS/Exchange.asmx', 'username', 'password'],
        indicator: 'text to prevent moderation',
        template: 'text you %{want} to replace',
        wait_time: '30s'

    def on_load
        @stop = false
        @started = false
        on_update
    end

    def on_unload
        @stop = true
    end
    
    def on_update
        @mappings = setting(:meeting_rooms)
        @indicator = setting(:indicator)
        @emails = Set.new(@mappings.keys.map { |email| email.to_s })
        @wait_time = setting(:wait_time) || '30s'
        @template = setting(:template)

        webex_user = setting(:webex_username)
        webex_pass = setting(:webex_password)
        @webex = Aca::Meetings::WebexApi.new(webex_user, webex_pass) if webex_user

        @appender = Aca::Meetings::EwsAppender.new(*setting(:config)) do |booking_request, appender|
            # This callback occurs on the thread pool
            begin
                find_primary_email(booking_request, appender)
            rescue => e
                logger.print_error e, "error appending text to email"
            end
        end

        start_scanning
    end


    protected


    def start_scanning
        return if @scanning

        @scanning = true
        @pending = []
        sys_info = {}

        # Moderate bookings in the thread pool
        logger.debug 'Checking for moderated emails...'
        task {
            @appender.moderate_bookings
        }.finally do
            logger.debug { "Found #{@pending.length} emails for moderation" }
            @pending.each do |booking|
                # Grab system reference and custom text
                booking.room_info = get_system_settings(booking.email, sys_info)
            end

            # Append bookings in the thread pool
            task {
                @pending.each do |booking|
                    if booking.room_info && booking.room_info.dial_in_text
                        webex = WebExDetails.new
                        webex.update = false

                        text = finish_template(booking.info, booking.room_info, webex)
                        booking.appender.append_booking(booking.info, text)
                    end
                end
            }.finally do
                @pending = []

                # =========================
                # Scan for chnaged bookings
                # =========================

                begin
                    logger.debug "Scanning calendars for location changes"

                    # Load a reference to all of the systems in question
                    @emails.each do |email|
                        if !sys_info[email]
                            get_system_settings(email, sys_info)
                        end
                    end
                rescue => e
                    logger.print_error e, "getting system settings"
                end

                # Scan each of the calendars for bookings that might have changed
                task {
                    sys_info.each do |email, info|
                        logger.debug { "- Checking calendar #{email}" }

                        begin
                            check_room_bookings(sys_info, email, info)
                        rescue => e
                            logger.print_error e, "checking #{email}"
                        end
                    end
                }.finally do
                    logger.debug { "Scanning complete. Waiting #{@wait_time} before next check" }

                    # Schedule the next scan
                    unless @stop
                        schedule.in(@wait_time) do
                            @scanning = false
                            start_scanning unless @stop
                        end
                    end
                end
            end
        end
    end


    Booking = Struct.new(:email, :info, :appender, :room_info)
    RoomInfo = Struct.new(:system, :detection, :dial_in_text, :timezone, :cmr_id)

    # NOTE:: this is always running in the thread pool
    # Called by @appender.moderate_bookings
    def find_primary_email(req, appender)
        emails = Set.new([req[:organizer]] + req[:attendees] + req[:resources])
        rooms = emails & @emails

        primary = rooms.first
        @pending << Booking.new(primary, req, appender)
    end

    # NOTE:: this is always running in the thread pool
    def check_room_bookings(sys_info, email, info)
        ews = @appender.cli
        ews.set_impersonation(Viewpoint::EWS::ConnectingSID[:SMTP], email)
        calendar = ews.get_folder(:calendar)
        entries = calendar.items_between(Time.now.midnight.iso8601, 1.weeks.from_now.iso8601)

        organizers = {}
        entries.each do |booking|
            booking.get_all_properties!
            org_email = booking.ews_item[:organizer][:elems][0][:mailbox][:elems][1][:email_address][:text]
            organizers[org_email] ||= []
            organizers[org_email] << booking
        end

        # Note:: the impersonation is changed here
        organizers.each do |org_email, bookings|
            begin
                bookings.each do |booking|
                    begin
                        email_info = {
                            organizer: org_email,
                            start: booking.ews_item[:start][:text],
                            uid: booking.ews_item[:u_i_d][:text],
                            end: booking.ews_item[:end][:text],
                            subject: booking.ews_item[:subject][:text]
                        }
                        resources, booking = @appender.get_resources(email_info)

                        next if resources.empty? || booking.nil?

                        detection = resources.select { |email| sys_info[email] }.collect { |email| sys_info[email].detection }.join('|')
                        webex = check_time_update(booking.body, email_info[:start], email_info[:end])
                        if booking.body =~ /(#{detection})/
                            # The calendar hasn't changed, let's check the time
                            if webex.out_of_sync
                                if webex.booking_id
                                    # Update booking here
                                    logger.debug { "--> Updating Webex meeting #{webex.account}: #{webex.booking_id}" }
                                    webex.update = true
                                    text = finish_template(email_info, info, webex)
                                    @appender.update_booking(org_email, booking.id, @indicator, text, 'SendToNone')
                                else
                                    # Create a booking here
                                    logger.debug { "--> No Webex meeting found, creating..." }
                                    text = finish_template(email_info, info, webex)
                                    @appender.update_booking(org_email, booking.id, @indicator, text)
                                end
                            end
                        else
                            # Check we have the webex booking ID
                            if webex.booking_id
                                logger.debug { "--> cancelling webex meeting #{webex.account}: #{webex.booking_id}" }
                                result = @webex.delete_booking(webex.booking_id, webex.account)
                                logger.debug { "    * webex cancel result #{result}" }
                            else
                                logger.debug { "--> No webex meeting found to cancel" }
                            end

                            logger.debug { "--> Creating Webex meeting" }
                            logger.debug { "--> Updating location of appointment: Organiser #{org_email}" }

                            text = finish_template(email_info, info, webex)
                            @appender.update_booking(org_email, booking.id, @indicator, text)
                        end

                    rescue => e
                        logger.print_error e, "unable to find meeting resources"
                    end
                end
            rescue => e
                logger.print_error e, "might not have permission to impersonate"
            end
        end
    end


    WebExDetails = Struct.new(:start, :ending, :booking_id, :account, :out_of_sync, :update, :pin, :host_pin)

    def check_time_update(body, start, ending)
        details = WebExDetails.new Time.parse(start).to_i, Time.parse(ending).to_i
        details.out_of_sync = false
        details.update = false

        if body =~ /!account!(.*?)!/
            details.account = $1

            if body =~ /!booking!(.*?)!/
                details.booking_id = $1

                if body =~ /!pin!(.*?)!/
                    details.pin = $1

                    # This is not out of sync temporarily
                    if body =~ /!host_pin!(.*?)!/
                        details.host_pin = $1
                    else
                        details.host_pin = details.pin
                    end

                    if body =~ /!starting!(.*?)!/
                        previous_start = $1.to_i

                        # Exit early if out of sync
                        if previous_start != details.start
                            details.out_of_sync = true
                            return details
                        end

                        if body =~ /!ending!(.*?)!/
                            previous_ending = $1.to_i
                            details.out_of_sync = true if previous_ending != details.ending
                        else
                            # If ending is missing then we want to re-sync
                            details.out_of_sync = true
                        end
                    else
                        # If starting is missing then we want to re-sync
                        details.out_of_sync = true
                    end
                else
                    details.out_of_sync = true
                end
            else
                details.out_of_sync = true
            end
        else
            details.out_of_sync = true
        end

        details
    end

    # NOTE:: this is not running in the thread pool (reactor thread)
    def get_system_settings(email, sys_info)
        sys_id = @mappings[email]

        if sys_id
            sys = systems(sys_id)

            if sys.available?
                config = sys.config

                # Dial in text is a key value hash
                dial_in_text = config.settings[:meetings][:dial_in_text]
                room_cmr = config.settings[:meetings][:cmr_id]
                room_timezone = config.settings[:meetings][:timezone]
                final_text = @template.gsub(/\%\{(.*?)\}/) { dial_in_text[$1.to_sym] }

                sys_info[email] = RoomInfo.new(sys, config.settings[:meetings][:detect_using], final_text, room_timezone, room_cmr)
            else
                logger.warn "System #{sys.id} (#{email}) was not available to approve email"
                nil
            end
        else
            logger.warn "No mapping found for moderated account #{email}"
            nil
        end
    end

    def finish_template(info, room_info, webex)
        text = room_info.dial_in_text
        timezone = room_info.timezone
        start  = Time.parse(info[:start])
        ending = Time.parse(info[:end])
        if timezone
            start  = start.in_time_zone timezone
            ending = ending.in_time_zone timezone
        end
        duration = ending - start

        meeting_id = webex.booking_id
        if webex.update
            result = @webex.update_booking({
                id: webex.booking_id,
                start: start,
                duration: (duration / 60).ceil + 5,
                host: webex.account,
                timezone: timezone
            })
            logger.debug { "    * webex update result #{result}" }
        elsif room_info.cmr_id
            webex.pin = generate_pin
            webex.host_pin = generate_host_pin
            meeting_id = @webex.create_booking({
                subject: info[:subject],
                description: info[:subject],
                start: start,
                duration: (duration / 60).ceil + 5,
                pin: webex.pin,
                host_pin: webex.host_pin,
                attendee: {
                    name: info[:organizer],
                    email: info[:organizer]
                },
                timezone: timezone,
                host: room_info.cmr_id
            })[:id]
        end

        text = text.gsub(/\$\{start_time\:(.*?)\}/) { start.strftime($1) }
        text = text.gsub(/\$\{end_time\:(.*?)\}/) { ending.strftime($1) }
        text = text.gsub('${subject}', info[:subject])
        text = text.gsub('${duration}', distance_of_time_in_words(start, ending))
        text = text.gsub('${timezone}', ActiveSupport::TimeZone[timezone].to_s)
        text = text.gsub('${booking}', meeting_id)
        text = text.gsub('${booking_pretty}', meeting_id.gsub(/(.{3})(?=.)/, '\1 \2'))
        text = text.gsub('${pin}', webex.pin.to_s)
        text = text.gsub('${host_pin}', webex.host_pin.to_s)

        text = text.gsub('!starting!!', "!starting!#{start.to_i}!")
        text = text.gsub('!ending!!', "!ending!#{ending.to_i}!")
        text = text.gsub('!account!!', "!account!#{room_info.cmr_id}!")
        text = text.gsub('!booking!!', "!booking!#{meeting_id}!")
        text = text.gsub('!pin!!', "!pin!#{webex.pin}!")
        text = text.gsub('!host_pin!!', "!host_pin!#{webex.host_pin}!")

        text
    end

    def generate_pin
        rand(1001...9998)
    end

    def generate_host_pin
        rand(100001...999998)
    end
end
