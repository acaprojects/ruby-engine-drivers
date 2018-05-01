# frozen_string_literal: true

module Aca; end
module Aca::Tracking; end

require 'aca/tracking/switch_port'
::Orchestrator::DependencyManager.load('Aca::Tracking::UserDevices', :model, :force)
::Aca::Tracking::UserDevices.ensure_design_document!

class Aca::Tracking::LocateUser
    include ::Orchestrator::Constants

    descriptive_name 'IP and Username to MAC lookup'
    generic_name :LocateUser
    implements :logic

    def on_load
        @looking_up = {}
    end

    def on_update
    end

    def lookup(*ips)
        ips.each do |ip, login, domain|
            perform_lookup(ip, login, domain)
        end
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
            recorded_login = self[mac]
            if recorded_login != login
                logger.warn { "removing #{mac} from recorded #{recorded_login} and reported #{login}" }
                user = ::Aca::Tracking::UserDevices.for_user(recorded_login)
                user.remove(mac)
            else
                logger.debug { "removing #{mac} from #{login}" }
            end

            user = ::Aca::Tracking::UserDevices.for_user(login, domain)
            user.remove(mac)

            self[mac] = nil
            self[ip] = nil
        ensure
            @looking_up.delete(ip)
        end
    end

    protected

    def perform_lookup(ip, login, domain)
        # prevents concurrent and repeat lookups for the one IP and user
        return if self[ip] == login || @looking_up[ip]
        begin
            @looking_up[ip] = true
            logger.debug { "Looking up #{ip} for #{domain}\\#{login}" }

            mac = Aca::Tracking::SwitchPort.find_by_device_ip(ip)&.mac_address

            if mac && self[mac] != login
                logger.debug { "MAC #{mac} found for #{ip} == #{login}" }

                user = ::Aca::Tracking::UserDevices.for_user(login, domain)
                user.add(mac)

                self[mac] = login
                self[ip] = login
            else
                logger.debug {
                    if mac
                        "MAC #{mac} known for #{ip} : #{login}"
                    else
                        "unable to locate MAC for #{ip}"
                    end
                }
            end
        rescue => e
            logger.print_error(e, "looking up #{ip}")
        ensure
            @looking_up.delete(ip)
        end
    end
end
