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
        check_every:  "1m",
        cancel_after: "15m",
        stale_after:  "1h",

        pressac_system_id: "sys-xxxxxxxx",
        pressac_device: "Websocket_1",
        sensor_zone_id: "zone-xxxxxxxx"
    })

    def on_load
        on_update
    end

    def on_update
        @bookings           = setting('bookings_device')
        @pressac_system     = setting('pressac_system_id')
        @pressac_device     = setting('pressac_device')
        @zone               = setting('sensor_zone_id')
        @sensor_name        = (setting('sensor_name') || setting('map_id')).to_sym
        @scan_cycle         = setting('check_every')
        @delay_until_cancel = UV::Scheduler.parse_duration(setting('cancel_after')) / 1000
        @stale_timeout      = UV::Scheduler.parse_duration(setting('stale_after')) / 1000
        self[:sensor_name]  = @sensor_name

        schedule.clear
        schedule.every(@scan_cycle) { determine_booking_presence }
        determine_booking_presence
    end

    def determine_booking_presence
        # Fetch current sensor data from Pressac Module
        sensor = systems(@pressac_system)[@pressac_device][:sensors]&.dig(@sensor_name)
        if sensor.nil?
            # Don't continue if the sensor does not exist
            msg =  "Pressac Booking Canceller: Sensor #{@sensor_name} NOT FOUND"
            logger.debug msg
            return msg
        end

        # Expose relevant sensor status
        now = Time.now.to_i
        self[:stale_sensor] = sensor_is_stale   = now - sensor[:last_update_epoch]  > @stale_timeout
        self[:motion] = sensor[:motion]
        if self[:motion]
            self[:became_busy] = Time.at(sensor[:became_busy]).to_s
            self[:became_free] = nil
            self[:vacant]      = prolonged_vacancy = false
            msg =  "Pressac Booking Canceller: Presence detected by #{@sensor_name}"
            logger.debug msg
            return msg
        else
            self[:became_busy] = nil
            self[:became_free] = Time.at(sensor[:became_free]).to_s
            self[:vacant]      = prolonged_vacancy = now - (sensor[:became_free] || now) > @delay_until_cancel         # If the sensor has been "free" for longer than the past X mins
        end

        if prolonged_vacancy && !sensor_is_stale
            self[:will_cancel] = true
            # Check each booking
            bookings = system[@bookings][:today]
            bookings&.each do |booking|
                next unless now < booking[:end_epoch]                               # Skip past bookings
                next unless now > booking[:start_epoch] + @delay_until_cancel       # Only consider bookings X mins after their start
                msg = "Pressac Booking Canceller: ENDING  \"#{booking[:Subject]}\" now"
                logger.debug msg
                truncate(booking)
                return msg
            end
        else
            self[:will_cancel] = false
        end
	    return 
    end

    def truncate(booking)
    	system[@bookings].end_meeting(booking[:id]).then do |response|
            logger.info "Pressac Booking Canceller: Ended #{booking[:Subject]} with response #{response}"
        end
    end
end
