module Aca; end
module Aca::Meetings; end


load File.expand_path('./ews_appender.rb', File.dirname(__FILE__))
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
                        text = finish_template(booking.info, booking.room_info)
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
    RoomInfo = Struct.new(:system, :detection, :dial_in_text, :timezone)

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
                        if not booking.body =~ /(#{detection})/
                            logger.debug { "--> Updating location of appointment: Organiser #{org_email}" }

                            text = finish_template(email_info, info)
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

    # NOTE:: this is not running in the thread pool (reactor thread)
    def get_system_settings(email, sys_info)
        sys_id = @mappings[email]

        if sys_id
            sys = systems(sys_id)

            if sys.available?
                config = sys.config

                # Dial in text is a key value hash
                dial_in_text = config.settings[:meetings][:dial_in_text]
                room_timezone = config.settings[:meetings][:timezone]
                final_text = @template.gsub(/\%\{(.*?)\}/) { dial_in_text[$1.to_sym] }

                sys_info[email] = RoomInfo.new(sys, config.settings[:meetings][:detect_using], final_text, room_timezone)
            else
                logger.warn "System #{sys.id} (#{email}) was not available to approve email"
                nil
            end
        else
            logger.warn "No mapping found for moderated account #{email}"
            nil
        end
    end

    def finish_template(info, room_info)
        text = room_info.dial_in_text
        timezone = room_info.timezone
        start  = Time.parse(info[:start])
        ending = Time.parse(info[:end])
        if timezone
            start  = start.in_time_zone timezone
            ending = ending.in_time_zone timezone
        end
        duration = ending - start

        text = text.gsub(/\$\{start_time\:(.*?)\}/) { start.strftime($1) }
        text = text.gsub(/\$\{end_time\:(.*?)\}/) { ending.strftime($1) }
        text = text.gsub('${subject}', info[:subject])
        text = text.gsub('${duration}', distance_of_time_in_words(start, ending))
        text = text.gsub('${timezone}', ActiveSupport::TimeZone[timezone].to_s)
        text
    end
end
