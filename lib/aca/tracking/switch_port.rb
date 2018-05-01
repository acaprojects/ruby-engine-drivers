# frozen_string_literal: true

module Aca; end
module Aca::Tracking
    class StaticDetails < ::Hash
        [
            :ip, :mac, :connected, :reserved, :reserve_time, :unplug_time,
            :reserved_by, :clash, :username, :desk_id, :connected_at
        ].each do |key|
            define_method key do
                self[key]
            end

            define_method "#{key}=" do |val|
                self[key] = val
            end
        end

        def reserved?
            (self[:unplug_time] + self[:reserve_time]) > Time.now.to_i
        rescue
            false
        end
    end
end

=begin
    Tracks currently connected device
    Tracks reservation and performs basic reservation management
      * if reserved is the reserved user sitting somewhere else (take over desk)
      * has the current user reserved somewhere else (cancel other booking)
=end

class Aca::Tracking::SwitchPort < CouchbaseOrm::Base
    design_document :swport

    # Connection details
    attribute :mac_address,  type: String # MAC of the device currently connected to the switch
    attribute :device_ip,    type: String # IP of the device connected to the switch
    attribute :username,     type: String # Username of the currently connected user
    attribute :connected_at, type: Integer, default: lambda { Time.now }

    # Reservation details
    attribute :unplug_time,  type: Integer, default: 0 # Unlug time for timeout
    attribute :reserve_time, type: Integer, default: 0 # Length of time for the reservation
    attribute :reserved_mac, type: String
    attribute :reserved_by,  type: String

    # Location details
    attribute :level,        type: String
    attribute :desk_id,      type: String
    attribute :building,     type: String

    # Switch details
    attribute :switch_ip,   type: String  # IP of the network switch
    attribute :hostname,    type: String  # defined on switch
    attribute :switch_name, type: String  # defined in backoffice
    attribute :interface,   type: String  # the switch port this device is connected

    validates :switch_ip,   presence: true
    validates :interface,   presence: true

    # self.find_by_switch_ip(ip) => Enumerator
    index_view :switch_ip

    # self.find_by_mac_address(mac) => nil or SwitchPort
    index :mac_address,  presence: false
    index :reserved_mac, presence: false
    index :device_ip,    presence: false

    def self.locate(mac)
        port = ::Aca::Tracking::SwitchPort.find_by_mac_address(mac)
        return port if port

        port = ::Aca::Tracking::SwitchPort.find_by_reserved_mac(mac)
        return port if port && (port.unplug_time + port.reserve_time) >= Time.now.to_i

        nil
    end

    # ================
    # EVENT PROCESSING
    # ================

    # A new device has connected to the switch port
    def connected(mac_address, reserve_time, **switch_details)
        reserved = reserved? && mac_address != self.reserved_mac
        if reserved
            # Check if the owner of this desk has moved somewhere else
            other = self.class.find_by_mac_address(self.reserved_mac)
            reserved = false if other&.id != self.id
        end

        username = self.class.bucket.get("macuser-#{mac_address}", quiet: true)

        if not reserved
            self.unplug_time = 0

            if username
                reserved = true
                self.reserve_time = reserve_time
                self.reserved_mac = mac_address
                self.reserved_by = username

                # Check this user hasn't reserved elsewhere
                other = self.class.find_by_mac_address(self.reserved_mac)
                other.update_reservation(0) if other
            else
                self.reserve_time = 0
                self.reserved_mac = nil
                self.reserved_by = nil
            end
        end
        self.username = username
        self.mac_address = mac_address
        self.assign_attributes(switch_details)
        self.connected_at = Time.now.to_i
        self.save!(with_cas: true)

        reserved
    rescue ::Libcouchbase::Error::KeyExists
        self.reload
        retry
    end

    # Change the owner of the desk to this new user
    def check_for_user(reserve_time)
        return false if !connected?

        # Check to see if the current user has been found
        username = self.username || self.class.bucket.get("macuser-#{self.mac_address}", quiet: true)
        return false unless username

        # Check if the owner of this desk has moved somewhere else
        if reserved? && self.mac_address != self.reserved_mac
            other = self.class.find_by_mac_address(self.reserved_mac)

            if other&.id == self.id
                if self.username.nil?
                    self.username = username
                    self.save!(with_cas: true)
                end
                return false
            end
        end

        self.reserved_by = username
        self.reserve_time = reserve_time
        self.reserved_mac = self.mac_address
        self.unplug_time = 0
        self.save!(with_cas: true)
        true
    rescue ::Libcouchbase::Error::KeyExists
        self.reload
        retry
    end

    # Update the reservation (user would like to extend their desk booking)
    def update_reservation(time)
        reserved = reserved?
        self.update_columns(reserve_time: time.to_i, with_cas: true) if reserved

        # Was the reservation request successful
        reserved
    rescue ::Libcouchbase::Error::KeyExists
        self.reload
        retry
    end

    def disconnected
        return false unless connected?

        # Configure pre-defined reservation on disconnect
        now = Time.now.to_i
        self.unplug_time = now if !reserved?
        self.mac_address = nil
        self.device_ip = nil
        self.username = nil
        self.save!(with_cas: true)

        # Ask user if they would like to reserve the desk
        # Don't need to notify them unless reserved and they own the desk
        self.reserve_time > 0 && now == self.unplug_time
    rescue ::Libcouchbase::Error::KeyExists
        self.reload
        retry
    end

    def reserved?
        (self.unplug_time + self.reserve_time) > Time.now.to_i
    end

    def connected?
        !!self.mac_address
    end

    def clash?
        connected? ? (self.reserved_mac != self.mac_address && reserved?) : false
    end

    # pre-calculated lightweight details for this switch port
    def details
        d = ::Aca::Tracking::StaticDetails.new
        d.ip = self.device_ip
        d.mac = self.mac_address || self.reserved_mac
        d.connected_at = self.connected_at
        d.connected = connected?
        d.clash = clash?

        # Reserved if there is a clash
        # Reserved if connected and macs are the same
        # Otherwise check if reserved in the traditonal sense
        res = reserved?
        d.reserved = d.clash ? true : (d.connected ? self.reserved_mac == self.mac_address : res)
        if res
            # Allow a realtime count down on the users screen
            d.reserve_time = self.reserve_time
            d.unplug_time = self.unplug_time
            d.reserved_by = self.reserved_by
        end
        d.username = self.username
        d.desk_id  = self.desk_id
        d
    end


    protected


    before_create :set_id
    def set_id
        self.id = "swport-#{self.switch_ip}-#{interface}"
    end
end
