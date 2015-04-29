require 'set'



# Seperate Room Joining module
# It just updates the System module with new inputs and outputs..

# Interface can connect to multiple systems!
# Inputs can be shared (VGA Removed?)
# Remote systems are communicated with directly


# Two types of room joining:
# 1. Shared Switcher + Shared Mixer
# * All inputs available
# * All ouputs available
# * Joined rooms can show the interface
# --------------------------
# 2. Chained Switchers + Independent Mixers
# * All of one rooms inputs available
# * Becomes an input to the next room
# * Joined rooms follow the master (should prevent user input?)


# Method of Control:
# 1. Shared switcher rooms
# * shared modules
# * apply module feedback to UI
# * control from any room
# ** Only show inputs for the current room
# ** Toggle: Show single output (Applied to all)
# ** Toggle: Show all the available ouputs
# ** Show which remote room source is applied (append room name)
# ** Apply Audio presets
# ** Adjust only source input volume

# 2. Chained Switchers
# * Inform other rooms of the Join
# ** These rooms will then switch to the joining rooms input
# *** Show new Tab on the touch panel and present that source
# ** Proxy any changes in volume


# Method of Abstraction:
# * Seperate logic module
# * System to have settings that indicate its use
# * Heavy use of UI logic

module Aca; end
class Aca::Joiner
    include ::Orchestrator::Constants

    
    def on_load
        on_update
    end

    def on_update
        # Grab the list of rooms and room details
        @systems = {}       # Provides system proxy lookup
        @system_id = system.id

        # System lookup occurs on a seperate thread returning a promise
        # Seems the database won't store an empty array and we don't want duplicates
        system_proxies = []
        rms = setting(:rooms)

        if rms.nil? || rms.empty?
            logger.debug "No room joining settings provided"
            rms = []
        end
        rms << @system_id.to_s

        rooms = Set.new(rms)
        rooms.each do |lookup|
            system_proxies << systems(lookup)
        end
        promise = thread.all(*system_proxies).then do |proxies|
            logger.debug "Room joining init success"
            build_room_list(proxies)
        end
        promise.catch do |err|
            logger.error "Failed to load joining systems with #{err.inspect}"
        end
    end

    def join(*ids)
        return if joining?

        start_joining

        # Ensure all id's are symbols
        ids.map! {|id| id.to_sym}

        # Grab only valid IDs
        rmset = Set.new(ids) & @rooms
        rmset << @system_id  # Add the current system to room joins list
        rooms = rmset.to_a

        logger.debug { "Joining #{rooms}" }

        # Inform the remote systems
        promise = inform(:join, rooms)
        promise.then do |to_inform|
            rms = Set.new
            to_inform.each do |room_list|
                # Finally returns results like [[result, success_bool],[result, success_bool]]
                rms += room_list[0]
            end

            # Warning as the UI should try to prevent this happening
            rms.each do |id|
                logger.warn "Notifying system #{id} of unjoin due to new join"
                @systems[id.to_sym][:Joiner].notify_unjoin
            end
        end
        promise.finally do
            commit_join(:join, @system_id, rooms)
            finish_joining
        end
    end

    def unjoin
        return if joining?

        start_joining

        # Grab only valid IDs
        rmset = Set.new(self[:joined][:rooms]) & @rooms
        rmset << @system_id
        rooms = rmset.to_a

        logger.debug { "Unjoining #{rooms}" }

        # Inform the remote systems
        promise = inform(:unjoin, rooms).finally do
            commit_join(:unjoin)
            finish_joining
        end
        promise
    end


    def perform_action(mod:, func:, index: 1, args: [], skipMe: false)
        promises = []

        # TODO:: Should warn people not to send arguments that might be modified
        # As multiple threads will be recieving these data structures
        rooms = self[:joined][:rooms]
        logger.debug { "Calling #{mod}->#{func} on #{rooms}" }
        rooms.each do |id_str|
            # Might have been pulled from the database
            id = id_str.to_sym
            next if skipMe && id == @system_id
            promises << @systems[id].get(mod, index).send(func.to_sym, *args)
        end

        # Allows you to perform an action after this has been processed on all systems
        thread.finally(*promises)
    end


    def notify_join(initiator, rooms)
        joined_to = self[:joined][:rooms]

        # Grab a list of rooms that need to be unjoined due to a new join
        if joined_to.size > 1
            remaining = joined_to - rooms
        else
            remaining = []
        end

        # Commit the newly joined rooms
        commit_join(:join, initiator, rooms, remaining)
    end

    def notify_unjoin
        commit_join(:unjoin)
    end


    protected


    def build_room_list(proxies)
        room_ids = []       # Provides ordering
        room_names = {}     # Provides simple name lookup

        proxies.each do |sys_proxy|
            @systems[sys_proxy.id] = sys_proxy
            room_ids << sys_proxy.id
            room_names[sys_proxy.id] = sys_proxy.name
        end

        self[:room_ids] = room_ids
        self[:rooms] = room_names
        @rooms = Set.new(room_ids)

        # Load any existing join settings from the database
        # Need to ensure everything is a symbol (database stores strings)
        dbVal = setting(:joined)
        if dbVal
            joined_to = dbVal[:rooms].map { |rm| rm.to_sym }
            self[:joined] = {
                initiator: dbVal[:initiator].to_sym,
                rooms: joined_to
            }
        else
            self[:joined] = {
                initiator: @system_id,
                rooms: [@system_id]
            }
        end
    end


    def start_joining
        self[:joining] = true
    end

    def finish_joining
        self[:joining] = false
    end

    def joining?
        self[:joining]
    end


    # Updates the join settings for the interface
    # Saves the current joins to the database
    def commit_join(join, init_id = nil, rooms = nil, remaining = nil)
        # Commit these settings to the database
        if join == :join
            logger.debug { "Join on #{rooms} by #{init_id}" }
            self[:joined] = {
                initiator: init_id,
                rooms: rooms
            }
        else
            logger.debug 'Unjoining'
            self[:joined] = {
                initiator: @system_id,
                rooms: [@system_id]
            }
        end

        define_setting(:joined, self[:joined])

        # Return the list of rooms that need to be unjoined
        remaining
    end

    # Inform the other systems of this systems details
    def inform(join, rooms)
        promises = []

        if join == :join
            rooms.each do |id|
                next if id == @system_id
                logger.debug "Notifying system #{id} of join"
                promises << @systems[id][:Joiner].notify_join(@system_id, rooms)
            end
        else
            rooms.each do |id|
                next if id == @system_id
                logger.debug "Notifying system #{id} of unjoin"
                promises << @systems[id][:Joiner].notify_unjoin
            end
        end

        thread.finally(*promises)
    end
end

