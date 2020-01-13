# encoding: ASCII-8BIT
require 'faraday'
require 'uv-rays'
require 'microsoft/office2'
require 'microsoft/office2/client'
Faraday.default_adapter = :libuv

module Aca; end
class Aca::O365BookingPanel
    include ::Orchestrator::Constants
    descriptive_name 'Office365 Room Booking Panel Logic'
    generic_name :Bookings
    implements :logic

    # Constants that the Room Booking Panel UI (ngx-bookings) will use
    RBP_AUTOCANCEL_TRIGGERED  = 'pending timeout'
    RBP_STOP_PRESSED        = 'user cancelled'

    # The room we are interested in
    default_settings({
        update_every: '2m',
        booking_cancel_email_message: 'The Stop button was presseed on the room booking panel',
        booking_timeout_email_message: 'The Start button was not pressed on the room booking panel',
        office_client_id: "enter client ID",
        office_secret: "enter client secret",
        office_tenant: "tenant_name_or_ID.onMicrosoft.com"
    })

    def on_load
        self[:today] = []
        on_update
    end

    def on_update
        self[:room_name] = setting(:room_name) || system.name
        self[:hide_all] = setting(:hide_all) || false
        self[:touch_enabled] = setting(:touch_enabled) || false
        self[:arrow_direction] = setting(:arrow_direction)
        self[:hearing_assistance] = setting(:hearing_assistance)
        self[:timeline_start] = setting(:timeline_start)
        self[:timeline_end] = setting(:timeline_end)
        self[:description] = setting(:description)
        self[:icon] = setting(:icon)
        self[:control_url] = setting(:booking_control_url) || system.config.support_url

        self[:timeout] = setting(:timeout)
        self[:disabled] = setting(:booking_disabled)
        self[:cancel_timeout] = UV::Scheduler.parse_duration(setting(:cancel_timeout)) / 1000 if setting(:booking_cancel_timeout)   # convert '1m2s' to '62'
        self[:cancel_email_message] = setting(:booking_cancel_email_message)
        self[:timeout_email_message] = setting(:booking_timeout_email_message)

	    self[:controlable] = setting(:booking_can_control)
        self[:searchable] = setting(:booking_can_search)

	    self[:catering] = setting(:booking_catering)
        self[:hide_details] = setting(:booking_hide_details)
        self[:hide_availability] = setting(:booking_hide_availability)
        self[:hide_user] = setting(:booking_hide_user)
        self[:hide_modal] = setting(:booking_hide_modal)


        self[:hide_all] = setting(:booking_hide_all)
	    self[:hide_title] = setting(:booking_hide_title)
        self[:hide_details] = setting(:booking_hide_details)
        self[:hide_description] = setting(:booking_hide_description)
        self[:hide_availability] = setting(:booking_hide_availability)

	    self[:hide_timeline] = setting(:booking_hide_timeline)
        self[:set_host] = setting(:booking_set_host)
        self[:set_title] = setting(:booking_set_title)
        self[:set_ext] = setting(:booking_set_ext)
        self[:search_user] = setting(:booking_search_user)
        self[:disable_future] = setting(:booking_disable_future)
        self[:min_duration] = setting(:booking_min_duration)
        self[:max_duration] = setting(:booking_max_duration)
        self[:duration_step] = setting(:booking_duration_step)
        self[:endable] = setting(:booking_endable)
        self[:ask_cancel] = setting(:booking_ask_cancel)
        self[:ask_end] = setting(:booking_ask_end)
        self[:default_title] = setting(:booking_default_title) || "On the spot booking"
        self[:select_free] = setting(:booking_select_free)
        self[:hide_all] = setting(:booking_hide_all) || false

        office_client_id  = setting(:office_client_id)  || ENV['OFFICE_CLIENT_ID']
        office_secret     = setting(:office_secret)     || ENV["OFFICE_CLIENT_SECRET"]
        office_token_path = setting(:office_token_path) || "/oauth2/v2.0/token"
        office_token_url  = setting(:office_token_url)  || ENV["OFFICE_TOKEN_URL"]  || "/" + setting(:office_tenant) + office_token_path
        @office_room = (setting(:office_room) || system.email)
        office_https_proxy = setting(:office_https_proxy)

        logger.debug "RBP>#{@office_room}>INIT: Instantiating o365 Graph API client"

        @client = ::Microsoft::Office2::Client.new({
            client_id:                  office_client_id,
            client_secret:              office_secret,
            app_token_url:              office_token_url,
            https_proxy:                office_https_proxy
        })

        self[:last_meeting_started] = setting(:last_meeting_started)
        self[:cancel_meeting_after] = setting(:cancel_meeting_after)
        
        schedule.clear
        schedule.in(rand(10000)) { fetch_bookings }
        fetch_interval = UV::Scheduler.parse_duration(setting(:update_every) || '5m') + rand(10000)
        schedule.every(fetch_interval) { fetch_bookings }
    end

    def fetch_bookings(*args)
        @todays_bookings = @client.get_bookings(mailboxes: [@office_room], options: {bookings_from: Time.now.midnight.to_i, bookings_to: Time.now.tomorrow.midnight.to_i}).dig(@office_room, :bookings)
        self[:today] = expose_bookings(@todays_bookings)
    end

    def create_meeting(params)
        start_param = params[:start] || params['start']
        end_param   = params[:end]   || params['end']
        
        unless start_param && end_param
            logger.debug "Error: start/end param is required and missing"
            raise "Error: start/end param is required and missing"
        end

        logger.debug "RBP>#{@office_room}>CREATE>INPUT:\n #{params}"

        host_email = params.dig(:host, :email)
        mailbox = host_email || @office_room
        calendargroup_id = nil
        calendar_id = nil

        booking_options = {
            subject:    params[:title] || setting(:booking_default_title),
            #location: {}
            attendees:  [ {email: @office_room, type: "resource"} ],
            timezone:   ENV['TZ'],
            extensions: { aca_booking: true }
        }
        if ENV['O365_PROXY_USER_CALENDARS']
            room_domain = @office_room.split('@').last
            user_domain = current_user.email.split('@').last
            
            calendar_proxy = host_email ? User.find_by_email(current_user.authority_id, host_email)&.calendar_proxy : nil
            mailbox = calendar_proxy&.dig(:account) if calendar_proxy&.dig(:account)
            calendargroup_id = calendar_proxy&.dig(:calendargroup_id)
            calendar_id = calendar_proxy&.dig(:calendar_id)

            booking_options[:attendees] << params[:host] if params[:host]
            booking_options[:extensions].merge!( { aca_proxied_organizer: [params.dig(:host, :name), host_email] })
        end
        begin
            result = @client.create_booking(
                        mailbox:        mailbox,
                        calendargroup_id: calendargroup_id,
                        calendar_id:    calendar_id,
                        start_param:    epoch(start_param), 
                        end_param:      epoch(end_param),
                        options: booking_options )
        rescue Exception => e
            logger.error "RBP>#{@office_room}>CREATE>ERROR: #{e.message}\n#{e.backtrace.join("\n")}"
            raise e
        else
            logger.debug { "RBP>#{@office_room}>CREATE>SUCCESS:\n #{result}" }
            schedule.in('2s') do
                fetch_bookings
            end
        end
        "Ok"
    end

    def start_meeting(meeting_ref)
        self[:last_meeting_started] = meeting_ref
        self[:meeting_pending] = meeting_ref
        self[:meeting_ending] = false
        self[:meeting_pending_notice] = false
        define_setting(:last_meeting_started, meeting_ref)
    end

    # New function for this or other engine modules to end meetings early based on sensors or other input.
    # Does not cancel or decline meetings - just shortens them to now.
    # This new method replaces the frontend app cancelling the booking, which has had many issues. Automated cancellations should be handled by backend modules for frontend apps
    def end_meeting(id)
        existing = @todays_bookings&.select {|b| b['id'] == id}
        return "Booking not found with id: #{id}" unless existing

        now = Time.now
        new_details = {}
        new_details[:end_param] = now.to_i
        new_details[:body] = existing[:body] << "\n\n========\n\n This meeting was ended at #{now.to_s} because no presence was detected in #{self[:room_name]}"
        
        @client.update_booking(booking_id: id, mailbox: @office_room, options: new_details)
    end

    # Legacy function for current/old ngx-booking frontends
    # - start_time is a string
    # This function will either:
    # - DELETE the booking from the room calendar (if the host if the room)
    # OR
    # - DECLINE the booking from the room calendar (if the host if a person, so that the person recieves a delcline message)
    #
    # The function is replaced by end_meeting(id) which has improvements and drawbacks:
    # + identify meeting by icaluid instead of start time, avoiding ambiguity
    # + The meeting will be edited in the room calendar: shortened to the current time. So that external retrospective analytics will still detect and count the meeting in the exchange mailbox.
    # + The body will be appended with "This meeting was ended at [time] because no presence was detected in the room"
    # - However currently  with end_meeting(), the user will not recieve an automated email notifications (these only get sent when the room declines-)
    # 
    def cancel_meeting(start_time, reason = "unknown reason")
        now = Time.now.to_i
        start_epoch = Time.parse(start_time).to_i
        ms_epoch = start_epoch * 1000
        too_early_to_cancel = now < start_epoch
        too_late_to_cancel = self[:cancel_timeout] ?  (now > (start_epoch + self[:cancel_timeout] + 180)) : false   # "180": allow up to 3mins of slippage, in case endpoint is not NTP synced
        bookings_to_cancel = bookings_with_start_time(start_epoch)

        if bookings_to_cancel > 1
            logger.warn { "RBP>#{@office_room}>CANCEL>CLASH: No bookings cancelled as Multiple bookings (#{bookings_to_cancel}) were found with same start time #{start_time}" } 
            return
        end
        if bookings_to_cancel == 0
            logger.warn { "RBP>#{@office_room}>CANCEL>NOT_FOUND: Could not find booking to cancel with start time #{start_time}" }
            return
        end

        case reason
        when RBP_STOP_PRESSED
            delete_o365_booking(start_epoch, reason)
        when RBP_AUTOCANCEL_TRIGGERED
            if !too_early_to_cancel && !too_late_to_cancel
                delete_o365_booking(start_epoch, reason)
            else
                logger.warn { "RBP>#{@office_room}>CANCEL>TOO_EARLY: Booking NOT cancelled with start time #{start_time}" } if too_early_to_cancel
                logger.warn { "RBP>#{@office_room}>CANCEL>TOO_LATE: Booking NOT cancelled with start time #{start_time}" } if too_late_to_cancel
            end
        else    # an unsupported reason, just cancel the booking and add support to this driver.
            logger.error { "RBP>#{@office_room}>CANCEL>UNKNOWN_REASON: Cancelled booking with unknown reason, with start time #{start_time}" }
            delete_o365_booking(start_epoch, reason)
        end
    
        self[:last_meeting_started] = ms_epoch
        self[:meeting_pending]      = ms_epoch
        self[:meeting_ending]       = false
        self[:meeting_pending_notice] = false
        true
    end

    def bookings_with_start_time(start_epoch)
        return 0 unless self[:today]
        booking_start_times = self[:today]&.map { |b| Time.parse(b[:Start]).to_i }
        return booking_start_times.count(start_epoch)
    end

    # If last meeting started !== meeting pending then
    #  we'll show a warning on the in room touch panel
    def set_meeting_pending(meeting_ref)
        self[:meeting_ending] = false
        self[:meeting_pending] = meeting_ref
        self[:meeting_pending_notice] = true
    end

    # Meeting ending warning indicator
    # (When meeting_ending !== last_meeting_started then the warning hasn't been cleared)
    # The warning is only displayed when meeting_ending === true
    def set_end_meeting_warning(meeting_ref = nil, extendable = false)
        if self[:last_meeting_started].nil? || self[:meeting_ending] != (meeting_ref || self[:last_meeting_started])
            self[:meeting_ending] = true

            # Allows meeting ending warnings in all rooms
            self[:last_meeting_started] = meeting_ref if meeting_ref
            self[:meeting_canbe_extended] = extendable
        end
    end

    def clear_end_meeting_warning
        self[:meeting_ending] = self[:last_meeting_started]
    end



    # Relies on frontend recieving this status variable update and acting upon it. Should result in a full page reload.
    # epoch is an integer, in seconds.
    def refresh_endpoints(epoch = nil)
        self[:reload] = epoch || Time.now.to_i + 300
    end
    
    protected

    # convert an unknown epoch type (s, ms, micros) to s (seconds) epoch
    def epoch(input)
        case input.digits.count
        when 1..12       #(s is typically 10 digits)
            input
        when 13..15       #(ms is typically 13 digits)
            input/1000
        else
            input/1000000
        end
    end

    def delete_or_decline(booking, comment = nil)
        if booking[:email] == @office_room
            logger.warn { "RBP>#{@office_room}>CANCEL>ROOM_OWNED: Deleting booking owned by the room, with start time #{booking[:Start]}" }
            response = @client.delete_booking(booking_id: booking[:id], mailbox: system.email)  # Bookings owned by the room need to be deleted, instead of declined
        else
            logger.warn { "RBP>#{@office_room}>CANCEL>SUCCESS: Declining booking, with start time #{booking[:Start]}" }
            response = @client.decline_meeting(booking_id: booking[:id], mailbox: system.email, comment: comment)
        end
    end

    def delete_o365_booking(delete_start_epoch, reason)
        bookings_deleted = 0
        delete_start_time = Time.at(delete_start_epoch)

        # Find a booking with a matching start time to delete
        self[:today].each_with_index do |booking, i|
            booking_start_epoch = Time.parse(booking[:Start]).to_i 
            next if booking_start_epoch != delete_start_epoch
            if booking[:isAllDay]
                logger.warn { "RBP>#{@office_room}>CANCEL>ALL_DAY: An All Day booking was NOT deleted, with start time #{delete_start_epoch}" }
                next
            end

            case reason
            when RBP_AUTOCANCEL_TRIGGERED
                response = delete_or_decline(booking, self[:timeout_email_message])
            when RBP_STOP_PRESSED
                response = delete_or_decline(booking, self[:cancel_email_message])
            else
                response = delete_or_decline(booking, "The booking was cancelled due to \"#{reason}\"")
            end
            if response.between?(200,204)
                bookings_deleted += 1
                fetch_bookings  # self[:today].delete_at(i) This does not seem to notify the websocket, so call fetch_bookings instead
            end
        end
    end

    def expose_bookings(bookings)
        results = []
        bookings.each{ |booking|
            tz = ActiveSupport::TimeZone.new(booking['start']['timeZone'])      # in tz database format: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
            start_time   = tz.parse(booking['start']['dateTime']).utc.iso8601    # output looks like: "2019-05-21 15:50:00 UTC"
            end_time     = tz.parse(booking['end']['dateTime']).utc.iso8601
            start_epoch = booking['start_epoch']
            end_epoch = booking['end_epoch']

            attendees = booking['attendees']
            if ENV['O365_PROXY_USER_CALENDARS']
                name =  booking.dig('attendees',1,:name)  || "Private"
                email = booking.dig('attendees',1,:email) || "Private"
            else
                email = booking.dig('organizer',:email)   || "Private"
                name =  booking.dig('organizer',:name)    || "Private"
            end

            subject = booking['subject']
            body    = booking['body']
            if ['private','confidential'].include?(booking['sensitivity'])
                name    = "Private"
                subject = "Private"
                body    = "Private"
            end

            results.push({
                :Start => start_time,
                :End => end_time,
                :start_epoch => start_epoch,
                :end_epoch => end_epoch,
                :Subject => subject,
                :body => body,
                :id => booking['id'],
                :icaluid => booking['icaluid'],
                :owner => name,
                :email => email,
                :organizer => {:name => name, :email => email},
                :attendees => attendees,
                :isAllDay => booking['isAllDay']
            })
        }
        results
    end
end
