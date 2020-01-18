# frozen_string_literal: true

# Designed to work with Pressac Desk sensors (Pressac::Sensors::WsProtocol) and ACA staff app frontend
module Pressac; end
class ::Pressac::BookingCanceller
    include ::Orchestrator::Constants

    descriptive_name 'Pressac Logic: Cancel Bookings if no Presence detected in room'
    generic_name :BookingCanceller
    implements :logic

    # Constants that the Room Booking Panel UI (ngx-bookings) will use
    RBP_AUTOCANCEL_TRIGGERED  = 'pending timeout'

    default_settings({
        bookings_device: "Bookings_1",
        desk_management_system_id: "sys-xxxxxxxx",
        desk_management_device: "DeskManagement_1",
        sensor_zone_id: "zone-xxxxxxxx",
        check_every: "1m",
        delay_until_cancel: "15m"
    })

    def on_load
        on_update
    end

    def on_update
        @subscriptions ||= []
        @subscriptions.each { |ref| unsubscribe(ref) }
        @subscriptions.clear

        @bookings     = setting('bookings_device')
        @desk_management_system = setting('desk_management_system_id')
        @desk_management_device = setting('desk_management_device')
        @zone         = setting('sensor_zone_id')
        @sensor       = setting('sensor_name') || setting('map_id')
        @scan_cycle   = setting('check_every')
        @cancel_delay = UV::Scheduler.parse_duration(setting('delay_until_cancel')) / 1000
        
        schedule.clear
        schedule.every(@scan_cycle) { determine_booking_presence }
    end

    def determine_booking_presence
        # Expose presence status
        all_sensors = systems(@desk_management_system)[@desk_management_device]
        unless  all_sensors[@zone + ':desk_ids'].include? @sensor  # don't continue if the sensor does not exist
            msg =  "Pressac Booking Canceller: Sensor #{@sensor} NOT FOUND in #{@zone}" unless all_sensors[@zone + ':desk_ids'].include? @sensor  # don't continue if the sensor does not exist
            logger.debug msg
            return msg
        end
        self[:presence] = all_sensors[@zone].include? @sensor

        # Check each booking
        now = Time.now.to_i
        bookings = system[@bookings][:today]
        bookings&.each do |booking|
            next unless now < booking[:end_epoch]      
            next unless (now + @cancel_delay) > booking[:start_epoch]
            logger.debug "Pressac Booking Canceller: \"#{booking[:Subject]}\" started at #{Time.at(booking[:start_epoch]).to_s} with #{@sensor} presence: #{self[:presence]}"
            if !self[:presence]
                msg = "Pressac Booking Canceller: ENDING  \"#{booking[:Subject]}\" now"
                logger.debug msg
                truncate(booking)
                return msg
            else
                msg = "Pressac Booking Canceller: No action for \"#{booking[:Subject]}\""
                logger.debug msg
                return msg
            end
        end
	    return 
    end

    def truncate(booking)
    	system[@bookings].end_meeting(booking[:id]).then do |response|
            logger.info "Ended #{booking[:Subject]} with response #{response}"
        end
    end
end
