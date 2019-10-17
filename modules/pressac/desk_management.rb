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
        sensor_to_desk_mappings: {
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
        @busy_delay = UV::Scheduler.parse_duration(setting('delaty_until_shown_as_busy') || '0m') / 1000
        @free_delay = UV::Scheduler.parse_duration(setting('delaty_until_shown_as_free') || '0m') / 1000

        # Initialize desk tracking variables to [] or 0, but keep existing values if they exist (||=)
        @desks_pending_busy ||= {}
        @desks_pending_free ||= {}
        
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

        @zones.each do |zone,gateways|
            gateways.each do |gateway|
                # Populate our initial status with the current data from all known sensors
                update_zone(zone, gateway.to_sym)
            end
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
        schedule.every('1m') { determine_desk_status }
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

    # Update one zone with the current data from one gateway
    def update_zone(zone, gateway)
        # The below values reflect just this ONE gateway, not neccesarily the whole zone
        begin
            gateway_data = system[@hub][:gateways][gateway] || {}
        rescue
            gateway_data = {}
        end
        logger.debug "#{zone}: #{gateway_data}"

        busy_desks = id gateway_data[:busy_desks]
        free_desks = id gateway_data[:free_desks]
        all_desks  = id gateway_data[:all_desks]

        self[zone+':desk_ids']   = self[zone] | all_desks
        self[zone+':desk_count'] = self[zone+':desk_ids'].count
        self[:last_update] = Time.now.in_time_zone($TZ).to_s
    end

    # Update desks_pending_busy/free hashes with a single sensor's data recieved from a notification
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
        desk_name = id([desk[:name]])&.first

        logger.debug "NOTIFICATION FROM DESK SENSOR============"
        logger.debug notification.value
        logger.debug desk[:gateway]

        if current_state[:motion] && !previous_state[:motion]
            @desks_pending_busy[desk_name] ||= { timestamp: Time.now.to_i, gateway: desk[:gateway]}
            @desks_pending_free.delete(desk_name)
        elsif !current_state[:motion] && previous_state[:motion]
            @desks_pending_free[desk_name] ||= { timestamp: Time.now.to_i, gateway: desk[:gateway]}
            @desks_pending_busy.delete(desk_name)
        end
        
        zone = which_zone(desk[:gateway])
        logger.debug "=======VALUE FOR ZONE: #{zone}, #{desk[:gateway]}"
        if zone
            zone = zone.to_s
            self[zone+':desk_ids']   = self[zone+':desk_ids'] | [desk_name]
            self[zone+':desk_count'] = self[zone+':desk_ids'].count
            self[:last_update] = Time.now.in_time_zone($TZ).to_s
        end
    end

    # return the (first) zone that a gateway is in
    def which_zone(gateway)
        @zones&.each do |zone, gateways|
            logger.debug "#{zone}: #{gateways}"
            return zone if gateways.include? gateway.to_s
        end
        nil
    end

    def determine_desk_status
        now = Time.now.to_i
        @desks_pending_busy.each do |desk,sensor|
            if sensor[:timestamp] + @busy_delay > now
                expose_desk_status(desk, which_zone(sensor[:gateway]), true)
                @desks_pending_busy.delete(desk)
            end
        end
        @desks_pending_free.each do |desk,sensor|
            if sensor[:timestamp] + @free_delay > now
                expose_desk_status(desk, which_zone(sensor[:gateway]), false) 
                @desks_pending_free.delete(desk)
            end
        end
        self[:desks_pending_busy] = @desks_pending_busy
        self[:desks_pending_free] = @desks_pending_free
    end

    def expose_desk_status(desk_name, zone, occupied)
        self[zone] = occupied ? (self[zone] | [desk_name]) : (self[zone] - [desk_name])
        self[zone+':occupied_count'] = self[zone].count
        persist_current_status
    end

    def persist_current_status
        status = {
            desks_pending_busy:  self[:busy_desks],
            desks_pending_free:  self[:free_desks],
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

    # Transform an array of Sensor Names to SVG Map IDs, IF the user has specified a mapping in settings(sensor_to_desk_mappings)
    def id(array)
        return [] if array.nil?
        array.map { |i| @desk_ids[i] || i } 
    end
end
