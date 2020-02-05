# frozen_string_literal: true

module Aca; end
class ::Aca::DeskBookings
    include ::Orchestrator::Constants

    descriptive_name 'ACA Desk Bookings Logic'
    generic_name :DeskBookings
    implements :logic

    default_settings({
        cancel_bookings_after: "1h",
        check_autocancel_every: "5m",
        zone_to_desk_ids: {
            "zone-xxx" => ["desk-01.001", "desk-01.002"],
            "zone-yyy" => ["desk-02.001", "desk-02.002"]
        }
    })

    def on_load
        system.load_complete do
            begin
                @status = {}
                on_update
            rescue => e
                logger.print_error e
            end
        end
    end

    def on_update
        # convert '1m2s' to '62'
        @autocancel_delay = UV::Scheduler.parse_duration(setting('cancel_bookings_after')  || '0s') / 1000
        @autocancel_scan_interval = setting('cancel_bookings_after')

        # local timezone of all the desks served by this logic (usually, all the desks in this building)
        @tz = setting('timezone') || ENV['TZ']

        @zone_of = {}
        saved_status    = setting('status') || {}
        @zones_to_desks = setting('zone_to_desk_ids') || {}
        @zones_to_desks.each do |zone, desks|
            # create reverse lookup: desk => zone
            desks.each { |desk| @zone_of[desk] = zone + ':bookings' }

            # expose all known desk ids
            self[zone] = @status[zone] = @zones_to_desks[zone]

            # load and expose previously saved status if there is no current status.
            self[zone+':bookings'] = @status[zone+':bookings'] ||= saved_status[zone+':bookings'] || []
        end
        
        schedule.clear
        schedule.every(@autocancel_scan_interval) { autocancel_bookings } if @autocancel_delay
    end

    # @param desk_id [String] the unique id that represents a desk
    def desk_details(*desk_ids)
        todays_date  = Time.now.in_time_zone(@tz).strftime('%F')    #e.g. 2020-12-31 in local time of the desk
        desk_ids.map { |desk| @status&.dig(zone_of(desk), desk, todays_date)&.first }
    end

    def book(desk_id, start_epoch)
        todays_date  = Time.now.in_time_zone(@tz).strftime('%F')    #e.g. 2020-12-31 in local time of the desk
        booking_date = Time.at(start_epoch).in_time_zone(@tz).strftime('%F')
        end_epoch    = Time.at(start_epoch).in_time_zone(@tz).midnight.tomorrow
        zone = zone_of[desk_id]

        new_booking = {    
            start: start_epoch, 
            end: end_epoch, 
            checked_in: (booking_date == todays_date) 
        }
        @status[zone][desk_id][booking_date][current_user.email] = new_booking    
        expose_status(zone)

        # Also store booking in user profile
        current_user.desk_bookings[booking_date] ||= {}
        current_user.desk_bookings[booking_date][desk_id] = new_booking
        current_user.save

        # STUB: Notify user of desk booking via email here
    end

    def cancel(desk_id, start_epoch)
        booking_date = Time.at(start_epoch).in_time_zone(@tz).strftime('%F')
        zone = zone_of[desk_id]
        raise "400 Error: No booking on #{booking_date} for #{current.email} at #{desk_id}" unless @status.dig(zone,desk_id,booking_date,user,start)

        @status[zone][desk_id][booking_date].delete(user)
        expose_status(zone)
        
        # Also delete booking from user profile
        current_user.desk_bookings[booking_date]&.delete(desk_id)
        current_user.save
    end

    # param checking_in is a bool: true = checkin, false = checkout
    def check_in(desk_id, checking_in)
        zone = zone_of[desk_id]
        todays_date  = Time.now.in_time_zone(@tz).strftime('%F')
        user = current_user.email
        raise "400 Error: No booking on #{todays_date} for #{current.email} at #{desk_id}" unless @status.dig(zone,desk_id,todays_date,user,start)
        if checking_in
            @status[zone][desk_id][todays_date][user][checked_in] = true
            current_user.desk_bookings[booking_date][desk_id][checked_in] = true
        else
            @status[zone][desk_id][todays_date].delete(user)
            current_user.desk_bookings[booking_date]&.delete(desk_id)
        end
        expose_status(zone)
        current_user.save
    end


    protected

    def expose_status(zone)
        self[zone+':bookings'] = @status[zone+':bookings']
        define_setting(:status, @status)    # Also persist new status to DB
    end

    def autocancel_bookings
        todays_date  = Time.now.in_time_zone(@tz).strftime('%F')
        now = Time.now

        @status.each do |zone|
            zone.each do |desk|
                desk[todays_date]&.each_with do |user_email, booking|
                    next if booking[checked_in]
                    next unless booking[:start] > now + @autocancel_delay
                    @status[zone][desk_id][todays_date].delete(user)
                    expose_status(zone)

                    next unless ENV['ENGINE_DEFAULT_AUTHORITY_ID']
                    user = User.find_by_email(ENV['ENGINE_DEFAULT_AUTHORITY_ID'], user_email)
                    user.desk_bookings[booking_date]&.delete(desk_id)
                    user.save
                    
                    # STUB: Notify user of cancellation by email here
                end
            end
        end
    end

end
