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
        sensor_name: "Pressac_PIR_sensor_name",
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
        @sensor       = setting('sensor_name')
        @scan_cycle   = setting('check_every')
        @cancel_delay = UV::Scheduler.parse_duration(setting('delay_until_cancel')) / 1000
        
        schedule.clear
        schedule.every(@scan_cycle) { determine_booking_presence }
    end

    def determine_booking_presence
        now = Time.now.to_i
        bookings = system[@bookings][:today]
        bookings&.each do |booking|
            logger.debug "Canceller: checking booking #{booking[:Subject]} with start #{booking[:start_epoch]} and current time #{now}"
            next unless booking[:start_epoch] > now + @cancel_delay
            all_sensors     = systems(@desk_management_system)[@desk_management_device]
            next unless all_sensors[@zone + ':desk_ids'].include? @sensor  # don't cancel if the sensor has not registered yet
            motion_detected = all_sensors[@zone].include? @sensor
            logger.debug "Canceller: #{@sensor} presence: #{motion_detected}"
            cancel(booking) unless motion_detected
        end
    end

    def cancel(booking)
        logger.debug "Canceller: CANCELLING booking #{booking[:Subject]}"
        system[@bookings].cancel_meeting(booking[:start_epoch], "pending timeout").then do |response|
            logger.info "Cancelled #{booking[:Subject]} with response #{response}"
        end
    end
end
