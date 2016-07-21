module Aca; end
module Aca::Meetings; end


load File.expand_path('./ews_appender.rb', File.dirname(__FILE__))
require 'set'


class Aca::Meetings::EwsDialInText
    include ::Orchestrator::Constants

    descriptive_name 'ACA Room Booking Text Appender'
    generic_name :MeetingAppender
    implements :logic

    default_settings meeting_rooms: {
            'room@org.com' => 'system_id'
        },
        config: ['https://org.com/EWS/Exchange.asmx', 'username', 'password'],
        wait_time: '30s'

    def on_load
        @started = false
        on_update
    end
    
    def on_update
        @mappings = setting(:meeting_rooms)
        @emails = Set.new(@mappings.keys.map { |email| email.to_s })
        @wait_time = setting(:wait_time)

        @appender = Aca::Meetings::Appender.new(*setting(:config)) do |booking_request, appender|
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
        task {
            @appender.moderate_bookings
        }.finally do
            @pending.each do |booking|
                # Grab system reference and custom text
                booking.dial_in_text = get_system_settings(booking.email, sys_info)
            end

            # Append bookings in the thread pool
            task {
                @pending.each do |booking|
                    if booking.dial_in_text
                        booking.appender.append_booking(booking.info, booking.dial_in_text)
                    end
                end
            }.finally do
                # =========================
                # Scan for chnaged bookings
                # =========================

                # Load a reference to all of the systems in question
                @emails.each do |email|
                    if !sys_info[email]
                        get_system_settings(email, sys_info)
                    end
                end

                # Scan each of the calendars for bookings that might have changed
                task {
                    sys_info.each_with_index do |info, email|
                        check_room_bookings(sys_info, email, info)
                    end
                }.finally do
                    # Schedule the next scan
                    schedule.in(@wait_time) do
                        @scanning = false
                        start_scanning
                    end
                end
            end
        end
    end


    Booking = Struct.new(:email, :info, :appender, :dial_in_text)
    RoomInfo = Struct.new(:system, :detection, :dial_in_text)

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
        update_required = []

        ews = @appender.cli
        ews.set_impersonation(Viewpoint::EWS::ConnectingSID[:SMTP], email)
        calendar = ews.get_folder(:calendar)
        entries = calendar.items_between(DateTime.now, 2.weeks.from_now, { item_shape: { additional_properties: { field_uRI: 'calendar:Resources'}, base_shape: 'AllProperties' } })
        items.each do |booking|
            resources = booking.ews_item[:resources][:elems].map{|e| e[:attendee][:elems][0][:mailbox][:elems][1][:email_address][:text] }
            detection = resources.select { |email| sys_info[email] }.collect { |email| sys_info[email].detection }.join('|')
            if not booking.body =~ /(#{detection})/
                # We need to update this booking
                update_required << booking
            end
        end

        # Note:: the impersonation is changed here
        update_required.each do |booking|
            organizer = @appender.get_elem(booking.ews_item[:meeting_request][:elems], :organizer)
            @appender.update_booking(organizer, booking.id, info.dial_in_text)
        end
    end

    # NOTE:: this is not running in the thread pool (reactor thread)
    def get_system_settings(email, sys_info)
        sys_id = @mappings[email]

        if sys_id
            sys = systems(sys_id)

            if sys.available?
                config = sys.config
                dial_in_text = config.settings[:meetings][:dial_in_text]

                sys_info[email] = RoomInfo.new(sys, config.settings[:meetings][:detect_using], dial_in_text)
                dial_in_text
            else
                logger.warn "System #{sys.id} (#{email}) was not available to approve email"
                nil
            end
        else
            logger.warn "No mapping found for moderated account #{email}"
            nil
        end
    end
end
