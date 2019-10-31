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
        zone_to_gateway_mappings: {
            "zone-xxx" => ["pressac_gateway_name_1"],
            "zone-zzz" => ["pressac_gateway_name_2", "pressac_gateway_name_3"]
        },
        sensor_name_to_desk_mappings: {
            "Note" => "This mapping is optional. If not present, the sensor NAME will be used and must match SVG map IDs",
            "Desk01" => "table-SYD.2.17.A",
            "Desk03" => "table-SYD.2.17.B"
        }
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
        # convert '1m2s' to '62'
        @busy_delay = UV::Scheduler.parse_duration(setting('delay_until_shown_as_busy') || '0m') / 1000
        @free_delay = UV::Scheduler.parse_duration(setting('delay_until_shown_as_free') || '0m') / 1000

        # Initialize desk tracking variables to [] or 0, but keep existing values if they exist (||=)
        @pending_busy ||= {}
        @pending_free ||= {}
        
        saved_status = setting('zzz_status')
        if saved_status
            saved_status&.each { |key, value| self[key] = value }
        else
            @zones.keys&.each do |zone_id|
                self[zone_id] = []
                self[zone_id+':desk_ids']       = []
                self[zone_id+':occupied_count'] = 0
                self[zone_id+':desk_count']     = 0
            end
        end

        # Create a reverse lookup (gateway => zone)
        @which_zone = {}
        @zones.each do |z, gateways|
            gateways.each {|g| @which_zone[g] = z}
        end
        
        # Subscribe to live updates from each gateway
        device,index = @hub.split('_')
        @zones.each do |zone,gateways|
            gateways.each do |gateway|
                @subscriptions << system.subscribe(device, index.to_i, gateway.to_sym) do |notification|
                    update_desk(notification)
                end
            end
        end
        schedule.clear
        schedule.every('30s') { determine_desk_status }
        #schedule.every('1h') { unexpose_unresponsive_desks }
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
        desk_name = id([desk[:name].to_sym])&.first.to_s

	    zone = @which_zone[desk[:gateway].to_s]
        logger.debug "===Updating: #{desk_name} in #{zone}"
        return unless zone

        if current_state[:motion] && !self[zone].include?(desk_name)      # if motion, and desk is currently free
            @pending_busy[desk_name] ||= { timestamp: Time.now.to_i, gateway: desk[:gateway]}
            @pending_free.delete(desk_name)
        elsif !current_state[:motion] && self[zone].include?(desk_name)   # if no motion, and desk is currently busy
            @pending_free[desk_name] ||= { timestamp: Time.now.to_i, gateway: desk[:gateway]}
            @pending_busy.delete(desk_name)
        end

        self[:last_update] = Time.now.in_time_zone($TZ).to_s
        self[:pending_busy] = @pending_busy
        self[:pending_free] = @pending_free
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
            if now > sensor[:timestamp] + @busy_delay
   	        zone = @which_zone[sensor[:gateway].to_s]
                new_status[zone][:busy] |= [desk] if zone
            end
        end
        @pending_free.each do |desk,sensor|
            if now > sensor[:timestamp] + @free_delay
	        zone = @which_zone[sensor[:gateway].to_s]
                new_status[zone][:free] |= [desk] if zone
            end
        end

        self[:new_status] = @new_status.deep_dup

        expose_desks(new_status)
        @pending_busy = {}
        @pending_free = {}
        self[:pending_busy] = {}
        self[:pending_free] = {}
    end

    def expose_desks(new_status)
	    new_status&.each do |z,desks|
	    zone = z.to_sym
	    self[zone] ||= []
	    self[zone]                = self[zone]          - desks[:free] | desks[:busy]
        self[z+':desk_ids']       = self[z+':desk_ids'] | desks[:free] | desks[:busy]
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
        array.map { |i| @desk_ids[i] || i } 
    end

    def unexpose_unresponsive_desks
        gateways = system[@hub][:gateways]
        gateways.each do |gateway, sensor|
            last_update = Time.parse(sensor[:timestamp])
            if Time.now > last_update + 1.hour
                desk_name = id([sensor[:name]]).first.to_s
                zone = @which_zone[sensor[:gateway]]
                self[zone]                   = self[zone] - [desk_name]
                self[zone+':desk_ids']       = self[zone+':desk_ids'] - [desk_name]
                self[zone+':desk_count']     = self[zone+':desk_ids'].count
                self[zone+':occupied_count'] = self[zone].count
            end
        end
    end
end
