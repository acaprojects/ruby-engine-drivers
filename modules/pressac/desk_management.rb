# frozen_string_literal: true

# Designed to work with Pressac Desk sensors (Pressac::Sensors::WsProtocol) and ACA staff app frontend
module Pressac; end
class ::Pressac::DeskManagement
    include ::Orchestrator::Constants

    descriptive_name 'Pressac Desk Bindings for ACA apps'
    generic_name :DeskManagement
    implements :logic

    default_settings({
        iot_hub_device: "Websocket_1",
        delay_until_shown_as_busy: "0m",
        delay_until_shown_as_free: "0m",
        stale_shown_as: "blank",
        zone_to_gateway_mappings: {
            "zone-xxx" => ["pressac_gateway_name_1"],
            "zone-zzz" => ["pressac_gateway_name_2", "pressac_gateway_name_3"]
        },
        sensor_name_to_desk_mappings: {
            "Note" => "This mapping is optional. If not present, the sensor NAME will be used and must match SVG map IDs",
            "Desk01" => "table-SYD.2.17.A",
            "Desk03" => "table-SYD.2.17.B"
        },
        custom_delays: [
            {
                "regex_match": "^Example[0-9]$",
                "delay_until_shown_as_busy": "5m",
                "delay_until_shown_as_free": "1h"
            }
 	]
    })

    def on_load
        system.load_complete do
            begin
                on_update
            rescue => e
                logger.print_error e
            end
        end
    end

    def on_update
        @subscriptions ||= []
        @subscriptions.each { |ref| unsubscribe(ref) }
        @subscriptions.clear

        @hub      = setting('iot_hub_device') || "Websocket_1"
        @zones    = setting('zone_to_gateway_mappings') || {}
        @desk_ids = setting('sensor_name_to_desk_mappings') || {}
        @stale_status  = setting('stale_shown_as')&.downcase&.to_sym || :blank
        @custom_delays = setting('custom_delays')&.map {|d| 
                            {
                                regex_match: d[:regex_match],
                                busy_delay: UV::Scheduler.parse_duration(d[:delay_until_shown_as_busy] || '0m') / 1000,
                                free_delay: UV::Scheduler.parse_duration(d[:delay_until_shown_as_free] || '0m') / 1000,
                            } 
                        } || []

        # convert '1m2s' to '62'
        @default_busy_delay = UV::Scheduler.parse_duration(setting('delay_until_shown_as_busy') || '0m') / 1000
        @default_free_delay = UV::Scheduler.parse_duration(setting('delay_until_shown_as_free') || '0m') / 1000

        # Initialize desk tracking variables to [] or 0, but keep existing values if they exist (||=)
        @pending_busy ||= {}
        @pending_free ||= {}
        
        saved_status = setting('zzz_status') || {}
        @zones.keys&.each do |zone_id|
            self[zone_id]                   ||= saved_status[zone_id] || []
            self[zone_id+':desk_ids']       ||= saved_status[zone_id+':desk_ids'] || []
            self[zone_id+':occupied_count'] = self[zone_id]&.count || 0
            self[zone_id+':desk_count']     = self[zone_id+'desk_ids']&.count || 0
        end

        # Create a reverse lookup (gateway => zone)
        @which_zone = {}
        @zones.each do |z, gateways|
            gateways.each {|g| @which_zone[g] = z}
        end
        
        # Subscribe to live updates from each gateway
        device,index = @hub.split('_')
        @subscriptions << system.subscribe(device, index.to_i, :stale) do |notification|
            unexpose_unresponsive_desks(notification)
        end
        @zones.each do |zone,gateways|
            gateways.each do |gateway|
                @subscriptions << system.subscribe(device, index.to_i, gateway.to_sym) do |notification|
                    update_desk(notification)
                end
            end
        end
        schedule.clear
        schedule.every('30s') { determine_desk_status }
    end

    # @param zone [String] the engine zone id
    def desk_usage(zone)
        self[zone] || []
    end

    # Since this driver cannot know which user is at which desk, just return nil
    # @param desk_id [String] the unique id that represents a desk
    def desk_details(*desk_ids)
        nil
    end


    protected

    # Update pending_busy/free hashes with a single sensor's data recieved from a notification
    def update_desk(notification)
        current_state  = notification.value
        previous_state = notification.old_value || {motion: false}
        # sample_state = {
        #     id:        string,
        #     name:      string,
        #     motion:    bool,
        #     voltage:   string,
        #     location:  string,
        #     timestamp: string,
        #     gateway:   string }
        desk = notification.value
        desk_name = id([desk[:name].to_sym])&.first

	    zone = @which_zone[desk[:gateway].to_s]
        logger.debug "PRESSAC > DESK > LOGIC: Updating #{desk_name} in #{zone}"
        return unless zone

        if current_state[:motion]
            @pending_busy[desk_name] ||= { timestamp: Time.now.to_i, gateway: desk[:gateway]}
            @pending_free.delete(desk_name)
        elsif !current_state[:motion]
            @pending_free[desk_name] ||= { timestamp: Time.now.to_i, gateway: desk[:gateway]}
            @pending_busy.delete(desk_name)
        end

        self[:last_update] = Time.now.in_time_zone($TZ).to_s
        self[:pending_busy] = @pending_busy
        self[:pending_free] = @pending_free
    end

    def delay_of(desk_id)
        @custom_delays.each do |setting|
            #regex = Regexp.new([:regex_match])
            if desk_id.match?(setting[:regex_match])
                logger.debug "PRESSAC > DESK > LOGIC: Regex MATCHED #{desk_id} to #{setting[:regex_match]}"
                return {busy: setting[:busy_delay], free: setting[:free_delay]} 
            end
        end
        return {busy: @default_busy_delay, free: @default_free_delay}
    end

    def determine_desk_status
        persist_current_status
        new_status = {}
        @zones.each do |zone, gateways|
            new_status[zone] =  {}
            new_status[zone][:busy] = new_status[zone][:free] = []
        end
        
        now = Time.now.to_i
        @pending_busy.each do |desk,sensor|
            if now > sensor[:timestamp] + delay_of(desk)[:busy]
   	            zone = @which_zone[sensor[:gateway].to_s]
                new_status[zone][:busy] |= [desk] if zone
                @pending_busy.delete(desk)
            end
        end
        @pending_free.each do |desk,sensor|
            if now > sensor[:timestamp] + delay_of(desk)[:free]
	            zone = @which_zone[sensor[:gateway].to_s]
                new_status[zone][:free] |= [desk] if zone
                @pending_free.delete(desk)
            end
        end

        self[:new_status]   = new_status.deep_dup
        self[:pending_busy] = @pending_busy.deep_dup
        self[:pending_free] = @pending_free.deep_dup
        expose_desks(new_status)
    end

    def expose_desks(new_status)
	    new_status&.each do |z,desks|
	    zone = z.to_sym
	    self[zone] ||= []
	    self[zone]                = self[zone]          - self[zone][:free] | self[zone][:busy]
        self[z+':desk_ids']       = self[z+':desk_ids'] | self[zone][:free] | self[zone][:busy]
        self[z+':desk_count']     = self[z+':desk_ids'].count
	    self[z+':occupied_count'] = self[zone].count
        end
    end

    def persist_current_status
        status = {
            pending_busy:        @pending_busy,
            pending_free:        @pending_free,
            last_update:         self[:last_update],
        }
        @zones.each do |zone, gateways|
            status[zone]                   = self[zone]
            status[zone+':desk_ids']       = self[zone+':desk_ids']
            status[zone+':desk_count']     = self[zone+':desk_count']
            status[zone+':occupied_count'] = self[zone+':occupied_count']
        end
        define_setting(:zzz_status, status)
    end

    # Transform an array of Sensor Names to SVG Map IDs, IF the user has specified a mapping in settings(sensor_name_to_desk_mappings)
    def id(array)
        return [] if array.nil?
	array.map { |i| @desk_ids[i] || i&.to_s } 
    end

    def unexpose_unresponsive_desks(notification)
        stale_sensors = notification.value
	    stale_ids = id(stale_sensors.map {|s| s.keys.first})

        logger.debug "PRESSAC > DESK > LOGIC: Displaying stale sensors as #{@stale_status}: #{stale_ids}"
        
        case @stale_status
        when :blank
            @zones.keys&.each do |zone_id|
                self[zone_id]                   = self[zone_id] - stale_ids
                self[zone_id+':desk_ids']       = self[zone_id+':desk_ids'] - stale_ids
                self[zone_id+':occupied_count'] = self[zone_id].count
                self[zone_id+':desk_count']     = self[zone_id+':desk_ids'].count
            end
        when :free
            @zones.keys&.each do |zone_id|
                self[zone_id]                   = self[zone_id] - stale_ids
                self[zone_id+':desk_ids']       = self[zone_id+':desk_ids'] | stale_ids
                self[zone_id+':occupied_count'] = self[zone_id].count
                self[zone_id+':desk_count']     = self[zone_id+':desk_ids'].count
            end
        when :busy
            @zones.keys&.each do |zone_id|
                self[zone_id]                   = self[zone_id] | stale_ids
                self[zone_id+':desk_ids']       = self[zone_id+':desk_ids'] | stale_ids
                self[zone_id+':occupied_count'] = self[zone_id].count
                self[zone_id+':desk_count']     = self[zone_id+':desk_ids'].count
            end
        end
    end
end
