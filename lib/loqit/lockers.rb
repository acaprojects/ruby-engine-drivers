require 'savon'
require 'active_support/time'
require 'digest/md5'
module Loqit; end

# require 'loqit/lockers'
# lockers = Loqit::Lockers.new(
#     username: 'xmltester',
#     password: 'xmlPassword',
#     wsdl: 'http://loqit.acgin.com.au/soap/server_wsdl.php?wsdl',
#     serial: 'BE434080-7277-11E3-BC4D-94C69111930A'
#     )
# random_locker = lockers.list_lockers.sample['number']
# random_status = lockers.show_status(random_locker)
# random_open = lockers.open_locker(random_locker)



class Loqit::Lockers
    def initialize(
            username:,
            password:,
            serial:,
            wsdl:,
            log: false,
            log_level: :debug
        )
        savon_config = {
            :wsdl => wsdl
        }

        @client = Savon.client savon_config
        @username = username
        @password = password
        @serial = serial
        @header = {
            header: {
                username: @username,
                password: Digest::MD5.hexdigest(@password),
                serialnumber: @serial
            }
        }
    end
    def list_lockers
        response = @client.call(:list_lockers,
            message: {
                unitSerial: @serial
            },
            soap_header: @header
        )
    end

end

