require 'set'



# Seperate Room Joining module
# It just updates the System module with new inputs and outputs..

# Interface can connect to multiple systems!
# Inputs can be shared (VGA Removed)
# Remote systems are communicated with directly


=begin
    
        # Grab the settings
        self[:sources] = setting(:sources)
        self[:outputs] = setting(:outputs)
        @join_presets = setting(:join_presets)

        # Grab the current state
        self[:state] = setting(:state) # Shutdown, Online
        self[:mode] = setting(:mode)   # Basic, User, Tech
        self[:tab] = setting(:tab)     # Current tab in that state

=end


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
        room_ids = []       # Provides ordering
        room_names = {}     # Provides simple name lookup
        @systems = {}       # Provides system proxy lookup
        setting(:rooms).each do |key, val|
            sys_proxy = systems(val)
            @systems[key] = sys_proxy
            room_ids << key
            room_names[key] = sys_proxy.name
        end
        self[:room_ids] = rooms
        self[:rooms] = room_names
        @rooms = Set.new(rooms)

        @system_id = system.id
    end

    def join(*ids)
        return if joining?

        start_joining

        # Grab only valid IDs
        rooms = Set.new(ids) & @rooms
        rooms << @system_id  # Add the current system to room joins list

        # Inform the remote systems
        inform(:join, rooms).finally do
            commit_join(:join, @system_id, rooms)
            finish_joining
        end
    end

    def unjoin(ids)
        return if joining?

        start_joining

        # Grab only valid IDs
        rooms = Set.new(ids) & @rooms
        rooms << @system_id

        # Inform the remote systems
        inform(:unjoin, rooms).finally do
            commit_join(:unjoin)
            finish_joining
        end
    end

    def notify_join(initiator, rooms)
        commit_join(:join, initiator, rooms)
    end

    def unjoin
        commit_join(:unjoin)
    end


    protected


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
    def commit_join(join, init_id = nil, rooms = nil)
        # Commit these settings to the database
        if join == :join
            define_setting(:joined, {
                initiator: init_id,
                rooms: rooms
            })
        else
            define_setting(:joined, nil)
        end

        self[:joined] = setting(:joined)
    end

    # Inform the other systems of this systems details
    def inform(join, rooms)
        promises = []

        if join == :join
            rooms.each do |id|
                next if id == @system_id
                promises << @systems[id][:Joiner].notify_join(@system_id, rooms)
            end
        else
            rooms.each do |id|
                next if id == @system_id
                promises << @systems[id][:Joiner].unjoin
            end
        end

        ::Libuv::Q.finally(thread, *promises)
    end
end

