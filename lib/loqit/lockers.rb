require 'savon'
require 'active_support/time'
require 'digest/md5'
module Loqit; end

# require 'loqit/lockers'
# lockers = Loqit::Lockers.new(
#     username: 'xmltester',
#     password: 'xmlPassword',
#     wsdl: 'http://10.224.8.2/soap/server_wsdl.php?wsdl',
#     serial: 'BE434080-7277-11E3-BC4D-94C69111930A'
# )
# all_lockers = lockers.list_lockers_detailed

# random_locker = all_lockers.sample
# locker_number = random_locker['number']
# locker_number = '31061'
# locker_number = '31025'
# locker_number = '30914'
# random_locker_status = lockers.show_locker_status(locker_number)
# random_locker_available = random_locker_status['LockerState']



# open_status = lockers.open_locker(locker_number)

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
            :wsdl => wsdl,
            :log => false,
            :log_level => :debug,
            :open_timeout => 1,
            :read_timeout => 1
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
        @queue = Queue.new
        Thread.new { process_requests! }
    end

    def new_request(name, *args)
        thread = Libuv::Reactor.current
        defer = thread.defer
        @queue << [defer, name, args]
        defer.promise.value
    end

    def new_ruby_request(name, *args, &block)
        @queue << [block, name, args]
    end

    def list_lockers
        response = @client.call(:list_lockers,
            message: {
                unitSerial: @serial
            },
            soap_header: @header
        ).body[:list_lockers_response][:return]
        JSON.parse(response)
    end

    def list_lockers_detailed(start_number:nil, end_number:nil)
        all_lockers_detailed = []

        if start_number
            (start_number.to_i..end_number.to_i).each do |num|
                # puts "WORKING ON NUMBER: #{num}"
                # locker_status = new_request('show_locker_status', [num.to_s])
                all_lockers_detailed.push(self.show_locker_status(num.to_s))
                # sleep 0.1
            end
        else
            all_lockers = self.list_lockers
            all_lockers[0..19].each_with_index do |locker, ind|
                # puts "WORKING ON NUMBER: #{num}"
                # locker_status = new_request('show_locker_status', [locker['number']])
                all_lockers_detailed.push(self.show_locker_status(locker['number']))
                # sleep 0.1
            end
        end
        all_lockers_detailed
    end

    def add_to_queue(locker_number)
    end

    def show_locker_status(locker_number, retries = 3)
        response = @client.call(:show_locker_status,
            message: {
                lockerNumber: locker_number,
                unitSerial:  @serial
            },
            soap_header: @header
        ).body[:show_locker_status_response][:return]
        JSON.parse(response)
    rescue Net::OpenTimeout
        puts "GOT FAILURE"
        puts "RETRIES: #{retries}"
        puts "---------------"
        retries -= 1
        retry if retries > 0
    end

    def open_locker(locker_number)
        response = @client.call(:open_locker,
            message: {
                lockerNumber: locker_number
            },
            soap_header: @header
        ).body[:locker_number_response][:return]
        JSON.parse(response)
    end

    def store_credentials(locker_number, user_pin_code, user_card, test_if_free=false)
        payload = {
            lockerNumber: locker_number,
            userPincode: user_pin_code
        }
        payload[:userCard] = user_card if user_card
        payload[:testIfFree] = test_if_free
        response = @client.call(:store_credentials,
            message: payload,
            soap_header: @header
        ).body[:store_credentials_response][:return]
        JSON.parse(response)
    end

    # this is untested
    def clear_credentials(locker_number)
        store_credentials(locker_number, '', '')
    end

    def customer_has_locker(user_card)
        response = @client.call(:customer_has_locker,
            message: {
                lockerNumber: locker_number,
                unitSerial:  @serial
            },
            soap_header: @header
        ).body[:customer_has_locker_response][:return]
        JSON.parse(response)
    end

     def process_requests!
        loop do
            defer, name, args = @queue.pop
            begin
                if defer.respond_to? :call
                    defer.call self.__send__(name, *args)
                else
                    defer.resolve self.__send__(name, *args)
                end
            rescue => e
                defer.reject e
            end
        end
    end
end
