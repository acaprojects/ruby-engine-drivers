require 'active_support/time'
require 'logger'
require 'viewpoint2'

module Microsoft; end

class Microsoft::Exchange
    TIMEZONE_MAPPING = {
        "Sydney": "AUS Eastern Standard Time"
    }
    def initialize(
            ews_url:,
            service_account_email:,
            service_account_password:,
            internet_proxy:nil,
            logger: Rails.logger
        )
        @ews_url = ews_url
        @service_account_email = service_account_email
        @service_account_password = service_account_password
        @internet_proxy = internet_proxy
        ews_opts = { http_opts: { ssl_verify_mode: 0 } }
        ews_opts[:http_opts][:http_client] = @internet_proxy if @internet_proxy
        STDERR.puts '--------------- NEW CLIENT CREATED --------------'
        STDERR.puts "At URL: #{@ews_url} with email: #{@service_account_email} and password #{@service_account_password}"
        STDERR.puts '-------------------------------------------------'
        @@ews_client ||= Viewpoint::EWSClient.new @ews_url, @service_account_email, @service_account_password, ews_opts
    end 

    def basic_text(field, name)
        field[name][:text]
    end

    def close
        @@ews_client.ews.connection.httpcli.reset_all
    end

    def email_list(field, name=nil)
        field[:email_addresses][:elems][-1][:entry][:text].gsub(/SMTP:|SIP:|sip:|smtp:/,'')
    end

    def phone_list(field, name=nil)
        phone = nil
        field[:phone_numbers][:elems].each do |entry|
            type = entry[:entry][:attribs][:key]
            text = entry[:entry][:text]

            next unless text.present?

            if type == "MobilePhone"
                return text
            elsif type == "BusinessPhone" || phone.present?
                phone = text
            end
        end
        phone
    end


    def get_users(q: nil, limit: nil)
        ews_users = @@ews_client.search_contacts(q)
        users = []
        fields = {
            display_name: 'name:basic_text',
            # email_addresses: 'email:email_list',
            phone_numbers: 'phone:phone_list',
            culture: 'locale:basic_text',
            department: 'department:basic_text'
        }
        keys = fields.keys
        ews_users.each do |user|
            begin
                output = {}
                user[:resolution][:elems][1][:contact][:elems].each do |field|
                    key = field.keys[0]
                    if keys.include?(key)
                        splits = fields[key].split(':')
                        output[splits[0]] = self.__send__(splits[1], field, key)
                    end
                end
                if output['name'].nil?
                    output['name'] = user[:resolution][:elems][0][:mailbox][:elems][0][:name][:text]
                end
                output['email'] = user[:resolution][:elems][0][:mailbox][:elems][1][:email_address][:text]
                users.push(output)
            rescue => e
                STDERR.puts "GOT USER WITHOUT EMAIL"
                STDERR.puts user
                STDERR.flush
            end
        end
        limit ||= users.length
        limit = limit.to_i - 1
        return users[0..limit.to_i]
    end

    def get_user(user_id:)
        get_users(q: user_id, limit: 1)[0]
    end

    def find_time(cal_event, time)
        elems = cal_event[:calendar_event][:elems]
        start_time = nil
        elems.each do |item|
            if item[time]
                Time.use_zone 'Sydney' do
                    start_time = Time.parse(item[time][:text])
                end
                break
            end
        end
        start_time
    end

    def get_available_rooms(rooms:, start_time:, end_time:)
        free_rooms = []

        STDERR.puts "Getting available rooms with"
        STDERR.puts start_time
        STDERR.puts end_time
        STDERR.flush 

        # Get booking data for all rooms between time range bounds
        user_free_busy = @@ews_client.get_user_availability(rooms,
            start_time: start_time,
            end_time:   end_time,
            requested_view: :detailed,
            time_zone: {
                bias: -600,
                standard_time: {
                    bias: -60,
                    time: "03:00:00",
                    day_order: 1,
                    month: 10,
                    day_of_week: 'Sunday'
                },
                daylight_time: {
                    bias: 0,
                    time: "02:00:00",
                    day_order: 1,
                    month: 4,
                    day_of_week: 'Sunday'
                }
            }
        )

       user_free_busy.body[0][:get_user_availability_response][:elems][0][:free_busy_response_array][:elems].each_with_index {|r,index|
            # Remove meta data (business hours and response type)
            resp = r[:free_busy_response][:elems][1][:free_busy_view][:elems].delete_if { |item| item[:free_busy_view_type] || item[:working_hours] }

            # Back to back meetings still show up so we need to remove these from the results
            if resp.length == 1
                resp = resp[0][:calendar_event_array][:elems]

                if resp.length == 0
                    free_rooms.push(rooms[index])
                elsif resp.length == 1
                    free_rooms.push(rooms[index]) if find_time(resp[0], :start_time) == end_time
                    free_rooms.push(rooms[index]) if find_time(resp[0], :end_time) == start_time
                end
            elsif resp.length == 0
                # If response length is 0 then the room is free
                free_rooms.push(rooms[index])
            end
        }
        free_rooms
    end

    def get_bookings(email:, start_param:DateTime.now.midnight, end_param:(DateTime.now.midnight + 2.days))
	begin
        if [Integer, String].include?(start_param.class)
            start_param = DateTime.parse(Time.at(start_param.to_i / 1000).to_s)
            end_param = DateTime.parse(Time.at(end_param.to_i / 1000).to_s)
        end
        STDERR.puts '---------------- GETTING BOOKINGS ---------------'
        STDERR.puts "At email: #{email} with start: #{start_param} and end: #{end_param}"
        STDERR.puts '-------------------------------------------------'
        bookings = []
        calendar_id = @@ews_client.get_folder(:calendar, opts = {act_as: email }).id
        events = @@ews_client.find_items(folder_id: calendar_id, calendar_view: {start_date: start_param, end_date: end_param})
        # events = @@ews_client.get_item(:calendar, opts = {act_as: email}).items
        events.each{|event|
            event.get_all_properties!
            booking = {}
            booking[:subject] = event.subject
            booking[:title] = event.subject
            # booking[:start_date] = event.start.utc.iso8601
            # booking[:end_date] = event.end.utc.iso8601
            booking[:start_date] = event.start.to_i * 1000
            booking[:end_date] = event.end.to_i * 1000
            booking[:body] = event.body
            booking[:organiser] = {
                name: event.organizer.name,
                email: event.organizer.email
            }
            booking[:attendees] = event.required_attendees.map {|attendee| 
                {
                    name: attendee.name,
                    email: attendee.email
                }
            } if event.required_attendees
            bookings.push(booking)
        }
        bookings
	rescue Exception => msg  
	    STDERR.puts msg
	    STDERR.flush
	    return []
	end
    end

    def create_booking(room_email:, start_param:, end_param:, subject:, description:nil, current_user:, attendees: nil, timezone:'Sydney')
        description = String(description)
        attendees = Array(attendees)


        booking = {}
        booking[:subject] = subject
        booking[:title] = subject
        booking[:start] = Time.at(start_param.to_i / 1000).utc.iso8601.chop
        # booking[:body] = description
        booking[:end] = Time.at(end_param.to_i / 1000).utc.iso8601.chop
        booking[:required_attendees] = [{
            attendee: { mailbox: { email_address: current_user.email } }
        }]
        attendees.each do |attendee|
            booking[:required_attendees].push({
                attendee: { mailbox: { email_address: attendee}}
            })
        end

        folder = @@ews_client.get_folder(:calendar, { act_as: room_email })
        appointment = folder.create_item(booking)
        {
            id: appointment.id,
            start: start_param,
            end: end_param,
            attendees: attendees,
            subject: subject
        }
    end

    def update_booking(booking_id:, room_id:, start_param:nil, end_param:nil, subject:nil, description:nil, attendees:nil, timezone:'Sydney')
        # We will always need a room and endpoint passed in
        room = Orchestrator::ControlSystem.find(room_id)
        endpoint = "/v1.0/users/#{room.email}/events/#{booking_id}"
        event = {}
        event[:subject] = subject if subject

        event[:start] = {
            dateTime: start_param,
            timeZone: TIMEZONE_MAPPING[timezone.to_sym]
        } if start_param

        event[:end] = {
            dateTime: end_param,
            timeZone: TIMEZONE_MAPPING[timezone.to_sym]
        } if end_param

        event[:body] = {
            contentType: 'html',
            content: description
        } if description

        # Let's assume that the request has the current user and room as an attendee already
        event[:attendees] = attendees.map{|a|
            { emailAddress: {
                    address: a[:email],
                    name: a[:name]
            }   }
        } if attendees

        response = JSON.parse(graph_request('patch', endpoint, event).to_json.value.body)['value']
    end

    # Takes a date of any kind (epoch, string, time object) and returns a time object
    def ensure_ruby_date(date) 
        if !(date.class == Time || date.class == DateTime)
            if string_is_digits(date)

                # Convert to an integer
                date = date.to_i

                # If JavaScript epoch remove milliseconds
                if date.to_s.length == 13
                    date /= 1000
                end

                # Convert to datetimes
                date = Time.at(date)           
            else
                date = Time.parse(date)                
            end
        end
        return date
    end

    # Returns true if a string is all digits (used to check for an epoch)
    def string_is_digits(string)
        string = string.to_s
        string.scan(/\D/).empty?
    end

end
