# frozen_string_literal: true

module Aca; end
module Aca::Tracking; end

require 'set'
require 'aca/tracking/switch_port'
::Orchestrator::DependencyManager.load('Aca::Tracking::UserDevices', :model, :force)
::Aca::Tracking::UserDevices.ensure_design_document!

class Aca::Tracking::LocateUser
    include ::Orchestrator::Constants
    include ::Orchestrator::Security

    descriptive_name 'IP and Username to MAC lookup'
    generic_name :LocateUser
    implements :logic

    default_settings({
        meraki_enabled: false,
        meraki_scanner: 'https://url.to.scanner',
        meraki_secret: 'give me access',
        cmx_enabled: false,
        cmx_host: 'http://cmxlocationsandbox.cisco.com',
        cmx_user: 'learning',
        cmx_pass: 'learning',
        ignore_vendors: {
            # https://en.wikipedia.org/wiki/MAC_address#Address_details
            'Good Way Docking Stations' => '0050b6',
            'BizLink Docking Stations' => '9cebe8'
        },
        ignore_hostnames: {},
        accept_hostnames: {},
        temporary_macs: {},
        ignore_users: {}
    })

    def on_load
        @looking_up = {}
        on_update
    end

    def on_update
        @meraki_enabled = setting(:meraki_enabled)
        if @meraki_enabled
            @scanner = UV::HttpEndpoint.new(setting(:meraki_scanner), {
                headers: {
                    Authorization: "Bearer #{setting(:meraki_secret)}"
                }
            })
        else
            @scanner = nil
        end

        @cmx_enabled = setting(:cmx_enabled)
        if @cmx_enabled
            @cmx = UV::HttpEndpoint.new(setting(:cmx_host), {
                headers: {
                    Authorization: [setting(:cmx_user), setting(:cmx_pass)]
                }
            })
        else
            @cmx = nil
        end

        self[:domain_controller_posted_at] ||= 0
        self[:radius_controller_posted_at] ||= 0
        self[:meraki_enabled] = @meraki_enabled
        self[:meraki_failed_requests] ||= 0
        self[:cmx_enabled] = @cmx_enabled
        self[:cmx_failed_requests] ||= 0

        @temporary = Set.new((setting(:temporary_macs) || {}).values)
        @blacklist = Set.new((setting(:ignore_vendors) || {}).values)
        @ignore_hosts = Set.new((setting(:ignore_hostnames) || {}).values)
        @accept_hosts = Set.new((setting(:accept_hostnames) || {}).values)
        @ignore_byod_hosts = Set.new((setting(:ignore_byod_hosts) || {}).values)
        @accept_byod_hosts = Set.new((setting(:accept_byod_hosts) || {}).values)
        @ignore_users = Set.new((setting(:ignore_users) || {}).values.map(&:downcase))
        @warnings ||= {}
        @filters ||= {}
    end

    protect_method :clear_warnings, :warnings, :clean_up, :macs_assigned_to, :check_ownership_of, :user_list, :remove_user

    # Provides a list of users and the black listed mac addresses
    # This allows one to update configuration of these machines
    attr_reader :warnings, :filters

    def clear_warnings
        @warnings = {}
    end

    def clear_filters
        @filters = {}
    end

    # Returns the mac addresses assigned to the current user
    def macs_assigned_to(username)
        {
            wired: ::Aca::Tracking::UserDevices.for_user(username).macs,
            wireless: ::Aca::Tracking::UserDevices.for_user("wifi_#{username}").macs,
            byod: ::Aca::Tracking::UserDevices.for_user("byod_#{username}").macs
        }
    end

    # Returns the username currently assigned to a MAC address
    def check_ownership_of(mac_address)
        ::Aca::Tracking::UserDevices.with_mac(mac_address).first&.username
    end

    # Get a list of all the users in the system
    def user_list
        usernames = Aca::Tracking::UserDevices.by_domain.to_a.map(&:username)
        usernames.map! do |name|
            if name.start_with?('wifi_') || name.start_with?('byod_')
                name = name.split('_', 2)[1]
            end
            name
        end
        Set.new(usernames).to_a.sort
    end

    # deletes a user from the database
    def remove_user(username, prefix = nil)
        models = []
        if prefix
            models << ::Aca::Tracking::UserDevices.for_user("#{prefix}#{username}")
        else
            models << ::Aca::Tracking::UserDevices.for_user(username)
            models << ::Aca::Tracking::UserDevices.for_user("wifi_#{username}")
            models << ::Aca::Tracking::UserDevices.for_user("byod_#{username}")
        end
        models.select!(&:persisted?)
        models.each(&:destroy)
        "removed #{models.length} entries"
    end

    # Removes all the references to a particular vendors mac addresses
    def clean_up(vendor_mac)
        count = 0

        view = Aca::Tracking::UserDevices.by_macs
        view.stream do |devs|
            macs = devs.macs.select { |mac| mac.start_with?(vendor_mac) }
            next if macs.empty?
            macs.each do |mac|
                count += 1
                devs.remove(mac)
            end
        end

        "cleaned up #{count} references"
    end

    def lookup(*ips)
        ttl = 10.minutes.ago.to_i
        ips.each do |ip, login, domain, hostname|
            next if @ignore_users.include?(login.downcase)
            perform_lookup(ip, login, domain, hostname, ttl)
        end

        self[:domain_controller_posted_at] = Time.now.to_i
    end

    # This is used to directly map MAC addresses to usernames
    # Typically from a RADIUS server like MS Network Policy Server
    def associate(*macs)
        macs.each do |mac, login, hostname|
            next if @ignore_users.include?(login.downcase)
            begin
                parts = login.split("\\")
                login = parts[-1]
                domain = parts[0]

                # Check the hostname is desirable
                next if hostname && check_hostname(domain, login, hostname, byod: true)
                username = ::User.bucket.get("macuser-#{mac}", quiet: true)

                # Don't overwrite domain controller discoveries
                # This differentiates BYOD from business devices
                if username.nil? || username.start_with?('byod_')
                    user = ::Aca::Tracking::UserDevices.for_user("byod_#{login}", domain)
                    user.add(mac)
                end
            rescue => e
                logger.print_error(e, "associating MAC #{mac} to #{login}")
            end
        end

        self[:radius_controller_posted_at] = Time.now.to_i
    end

    # For use with shared desktop computers that anyone can log into
    # Optimally only these machines should trigger this web hook
    def logout(ip, login, domain = nil)
        # Ensure only one operation per-IP is performed at a time
        return if @looking_up[ip]
        begin
            @looking_up[ip] = true

            # Find the mac address of the IP address logging out
            mac = Aca::Tracking::SwitchPort.find_by_device_ip(ip)&.mac_address
            return unless mac

            # Remove the username details recorded for this MAC address
            recorded_login = @filters[mac]
            if recorded_login != login
                logger.warn { "removing #{mac} from recorded #{recorded_login} and reported #{login}" }
                user = ::Aca::Tracking::UserDevices.for_user(recorded_login)
                user.remove(mac)
            else
                logger.debug { "removing #{mac} from #{login}" }
            end

            user = ::Aca::Tracking::UserDevices.for_user(login, domain)
            user.remove(mac)

            @filters[mac] = nil
            @filters[ip] = nil
        ensure
            @looking_up.delete(ip)
        end
    end

    protected

    def check_hostname(domain, login, hostname, byod: false)
        if byod
            accept_hosts = @accept_byod_hosts
            ignore_hosts = @ignore_byod_hosts
        else
            accept_hosts = @accept_hosts
            ignore_hosts = @ignore_hosts
        end

        # Default to true if accept hosts filter is present
        ignore_host = !accept_hosts.empty?
        check = hostname.downcase

        accept_hosts.each do |host|
            if check.start_with? host
                ignore_host = false
                break
            end
        end

        ignore_hosts.each do |host|
            if check.start_with? host
                ignore_host = true
                break
            end
        end

        if ignore_host
            logger.debug { "ignoring hostname #{hostname} due to filter" }
            return ignore_host
        end
        save_hostname_mapping(domain, login, hostname) if @filters[hostname] != login
        ignore_host
    end

    def perform_lookup(ip, login, domain, hostname, ttl)
        return if hostname && check_hostname(domain, login, hostname)

        # prevents concurrent and repeat lookups for the one IP and user
        return if @filters[ip] == login || @looking_up[ip]
        begin
            @looking_up[ip] = true
            logger.debug { "Looking up #{ip} for #{domain}\\#{login}" }

            mac = Aca::Tracking::SwitchPort.find_by_device_ip(ip)&.mac_address
            if mac
                check = mac[0..5]
                if @blacklist.include?(check)
                    logger.warn "blacklisted device detected for #{domain}\\#{login}"
                    @warnings[login] = mac
                    return
                elsif @temporary.include?(check)
                    @warnings[login] = mac
                    if User.bucket.get("temporarily_block_mac-#{mac}", quiet: true)
                        logger.warn "Ignoring temporary mac for #{domain}\\#{login} during transition period"
                        return
                    end
                end
            end

            # We search the wireless networks in case snooping is enabled on the
            # port that the wireless controller is connected to
            if @meraki_enabled
                resp = @scanner.get(path: "/meraki/#{ip}").value
                if resp.status == 200
                    details = JSON.parse(resp.body, symbolize_names: true)

                    if details[:seenEpoch] > ttl
                        wifi_mac = details[:clientMac]

                        if @filters[wifi_mac] != login
                            logger.debug { "Meraki found #{wifi_mac} for #{ip} == #{login}" }

                            # NOTE:: Wireless MAC addresses stored seperately from wired MACs
                            user = ::Aca::Tracking::UserDevices.for_user("wifi_#{login}", domain)
                            user.add(wifi_mac)

                            @filters[wifi_mac] = login
                            @filters[ip] = login
                            return
                        end
                    end
                elsif resp.status != 404
                    self[:meraki_failed_requests] += 1
                    self[:meraki_failure] = {
                        time: Time.now.to_i,
                        code: resp.status
                    }
                end
            end

            if @cmx_enabled
                resp = @cmx.get(path: '/api/location/v2/clients', query: {ipAddress: ip}).value
                if resp.status != 204 && (200...300).include?(resp.status)
                    locations = JSON.parse(resp.body, symbolize_names: true)
                    if locations.present? && locations[0][:currentlyTracked] == true
                        wifi_mac = locations[0][:macAddress]

                        if @filters[wifi_mac] != login
                            logger.debug { "CMX found #{wifi_mac} for #{ip} == #{login}" }

                            # NOTE:: Wireless MAC addresses stored seperately from wired MACs
                            user = ::Aca::Tracking::UserDevices.for_user("wifi_#{login}", domain)
                            user.add(wifi_mac)

                            @filters[wifi_mac] = login
                            @filters[ip] = login
                            return
                        end
                    end
                elsif resp.status != 204
                    self[:cmx_failed_requests] += 1
                    self[:cmx_failure] = {
                        time: Time.now.to_i,
                        code: resp.status
                    }
                end
            end

            if mac && @filters[mac] != login
                # Don't move wifi devices to desk tracking system
                username = ::User.bucket.get("macuser-#{mac}", quiet: true)
                if username && (username.start_with?('byod_') || username.start_with?('wifi_'))
                    logger.debug { "MAC #{mac} has been assigned as a WIFI device - ignoring" }
                else
                    logger.debug { "MAC #{mac} found for #{ip} == #{login}" }
                    user = ::Aca::Tracking::UserDevices.for_user(login, domain)
                    user.add(mac)
                end

                @filters[mac] = login
                @filters[ip] = login
            elsif mac.nil?
                logger.debug { "unable to locate MAC for #{ip}" }
            end
        rescue => e
            logger.print_error(e, "looking up #{ip}")
        ensure
            @looking_up.delete(ip)
        end
    end

    def save_hostname_mapping(domain, username, hostname)
        logger.debug { "Found new machine #{hostname} for #{username}" }

        key = "wifihost-#{domain.downcase}-#{username.downcase}"
        bucket = User.bucket
        existing = bucket.get(key, quiet: true)

        if existing
            if existing[:hostname] == hostname
                logger.debug { "ignoring #{hostname} as already in database" }
                @filters[hostname] = username
                return
            end
            existing[:hostname] = hostname
            existing[:updated] = Time.now.to_i
            bucket.set(key, existing)
        else
            time = Time.now.to_i
            data = {
                hostname: hostname,
                username: username,
                domain: domain,
                created: time,
                updated: time
            }
            bucket.set(key, data)
        end

        @filters[hostname] = username
    end
end
