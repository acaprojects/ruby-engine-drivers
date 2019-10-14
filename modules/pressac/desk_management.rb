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
        @desk_ids = setting('sensor_to_desk_mappings') || {}

        # Initialize desk tracking variables to [] or 0, but keep existing values if they exist (||=)
        @desks_pending_busy ||= {}
        @desks_pending_free ||= {}
        
        @zones.keys.each do |zone_id|
            self[zone_id] ||= []                     # occupied (busy) desk ids in this zone
            self[zone_id+':desk_ids']       ||= []   # all desk ids in this zone
            self[zone_id+':occupied_count'] ||= 0
            self[zone_id+':desk_count']     ||= 0
        end

        @zones.each do |zone,gateways|
            gateways.each do |gateway|
                # Populate our initial status with the current data from all known sensors
                update_zone(zone, gateway)
            end
        end
        
        # Subscribe to live updates from each gateway
        device,index = @hub.split('_')
        @zones.each do |zone,gateways|
            gateways.each do |gateway|
                @subscriptions << system.subscribe(device, index.to_i, gateway) do |notification|
                    update_zone(zone, gateway, notification)
                end
            end
        end
    end

    # Update one zone with the current data from one gateway
    def update_zone(zone, gateway, notification=nil)
        # The below values reflect just this ONE gateway, not neccesarily the whole zone
        all_desks  = id system[@hub][gateway][:all_desks]
        busy_desks = id system[@hub][gateway][:busy_desks]
        free_desks = all_desks - busy_desks

        # add the desks from this sensor to the zone's list and count of all ids
        self[zone+':desk_ids']   = self[zone] | all_desks
        self[zone+':desk_count'] = self[zone+':desk_ids'].count
        self[:last_update] = Time.now.in_time_zone($TZ).to_s

        # determine desks that changed state, and track time of change
        previously_free = notification.old_value
        previously_busy = all_desks  - previously_free
        newly_free      = free_desks - previously_free
        newly_busy      = busy_desks - previously_busy
        logger.debug "Newly free: #{newly_free}\nNewly busy: #{newly_busy}"

        newly_free.each { |d| desks_pending_free[d] ||= Time.now.to_i; desks_pending_busy.delete(d) }
        newly_busy.each { |d| desks_pending_busy[d] ||= Time.now.to_i; desks_pending_free.delete(d) }
        self[:newly_free] = newly_free
        self[:newly_busy] = newly_busy
    end

    def expose_desk_status(zone, busy_desks, free_desks)
        # Finally, let dependant apps know that that these desks have changed state
        self[zone] = (self[zone] | busy_desks) - free_desks
        self[zone+':occupied_count'] = self[zone].count
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

    # Transform an array of Sensor Names to SVG Map IDs, IF the user has specified a mapping in settings(sensor_to_desk_mappings)
    def id(array)
        return [] if array.nil?
        array.map { |i| @desk_ids[i] || i } 
    end
end
