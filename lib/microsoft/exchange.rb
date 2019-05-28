require 'active_support/time'
require 'logger'

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
            hide_all_day_bookings:false,
            logger: Rails.logger
        )
        begin
            require 'viewpoint2'
            rescue LoadError
            STDERR.puts 'VIEWPOINT NOT PRESENT'
            STDERR.flush
        end
        @ews_url = ews_url
        @service_account_email = service_account_email
        @service_account_password = service_account_password
        @internet_proxy = internet_proxy
        @hide_all_day_bookings = hide_all_day_bookings
        ews_opts = { http_opts: { ssl_verify_mode: 0 } }
        ews_opts[:http_opts][:http_client] = @internet_proxy if @internet_proxy
        STDERR.puts '--------------- NEW CLIENT CREATED --------------'
        STDERR.puts "At URL: #{@ews_url} with email: #{@service_account_email}"
        STDERR.puts '-------------------------------------------------'
        @ews_client ||= Viewpoint::EWSClient.new @ews_url, @service_account_email, @service_account_password, ews_opts
    end 

    def basic_text(field, name)
        field[name][:text]
    end

    def close
        @ews_client.ews.connection.httpcli.reset_all
    end

    def username(field, name=nil)
        username = field[:email_addresses][:elems][0][:entry][:text].split("@")[0]
        if ['smt','sip'].include?(username.downcase[0..2])
            username = username.gsub(/SMTP:|SIP:|sip:|smtp:/,'')
        else
            username = field[:email_addresses][:elems][-1][:entry][:text].split("@")[0]
            if ['smt','sip'].include?(username.downcase[0..2])
                username = username.gsub(/SMTP:|SIP:|sip:|smtp:/,'')
            else
                username = field[:email_addresses][:elems][1][:entry][:text].split("@")[0]
                if ['smt','sip'].include?(username.downcase[0..2])
                    username = username.gsub(/SMTP:|SIP:|sip:|smtp:/,'')
                else
                    username = nil
                end
            end
        end
        username
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
        ews_users = @ews_client.search_contacts(q)
        users = []
        fields = {
            display_name: 'name:basic_text',
            phone_numbers: 'phone:phone_list',
            culture: 'locale:basic_text',
            department: 'department:basic_text',
            email_addresses: 'id:username'
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
                start_time = ActiveSupport::TimeZone.new("UTC").parse(item[time][:text])
                break
            end
        end
        start_time
    end

    def get_available_rooms(rooms:, start_time:, end_time:)
        free_rooms = []
        start_time = start_time.utc
        end_time = end_time.utc
        STDERR.puts "Getting available rooms with"
        STDERR.puts start_time
        STDERR.puts end_time
        STDERR.flush

        rooms.each_slice(30).each do |room_subset|

            # Get booking data for all rooms between time range bounds
            user_free_busy = @ews_client.get_user_availability(room_subset,
                start_time: start_time,
                end_time:   end_time,
                requested_view: :detailed,
                time_zone: {
                    bias: -0,
                    standard_time: {
                        bias: 0,
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
                        free_rooms.push(room_subset[index])
                    elsif resp.length == 1
                        free_rooms.push(room_subset[index]) if find_time(resp[0], :start_time).to_i == end_time.to_i
                        free_rooms.push(room_subset[index]) if find_time(resp[0], :end_time).to_i == start_time.to_i
                    end
                elsif resp.length == 0
                    # If response length is 0 then the room is free
                    free_rooms.push(room_subset[index])
                end
            }
        end

        free_rooms
    end

    def get_bookings(email:, start_param:DateTime.now.midnight, end_param:(DateTime.now.midnight + 2.days), use_act_as: false)
	begin
        # Get all the room emails
        room_emails = Orchestrator::ControlSystem.all.to_a.map { |sys| sys.email }
        if [Integer, String].include?(start_param.class)
            start_param = DateTime.parse(Time.at(start_param.to_i / 1000).to_s)
            end_param = DateTime.parse(Time.at(end_param.to_i / 1000).to_s)
        end
        STDERR.puts '---------------- GETTING BOOKINGS ---------------'
        STDERR.puts "At email: #{email} with start: #{start_param} and end: #{end_param}"
        STDERR.puts '-------------------------------------------------'
        bookings = []
        if use_act_as
            calendar_id = @ews_client.get_folder(:calendar, opts = {act_as: email }).id
            events = @ews_client.find_items(folder_id: calendar_id, calendar_view: {start_date: start_param, end_date: end_param})
        else
            @ews_client.set_impersonation(Viewpoint::EWS::ConnectingSID[:SMTP], email)
            events = @ews_client.find_items({:folder_id => :calendar, :calendar_view => {:start_date => start_param.utc.iso8601, :end_date => end_param.utc.iso8601}})
        end
        # events = @ews_client.get_item(:calendar, opts = {act_as: email}).items
        events.each{|event|
            event.get_all_properties!
            internal_domain = Mail::Address.new(event.organizer.email).domain
            booking = {}
            booking[:subject] = event.subject
            booking[:title] = event.subject
            booking[:id] = event.id
            # booking[:start_date] = event.start.utc.iso8601
            # booking[:end_date] = event.end.utc.iso8601
            booking[:start] = event.start.to_i * 1000
            booking[:end] = event.end.to_i * 1000
            booking[:body] = event.body
            booking[:organiser] = {
                name: event.organizer.name,
                email: event.organizer.email
            }
            booking[:attendees] = event.required_attendees.map {|attendee|
                if room_emails.include?(attendee.email)
                    booking[:room_id] = attendee.email
                    next
                end
                email_domain = Mail::Address.new(attendee.email).domain
                {
                    name: attendee.name,
                    email: attendee.email,
                    visitor: (internal_domain != email_domain),
                    organisation: attendee.email.split('@')[1..-1].join("").split('.')[0].capitalize
                }
            }.compact if event.required_attendees
            if @hide_all_day_bookings
                STDERR.puts "SKIPPING #{event.subject}"
                STDERR.flush
                next if event.end.to_time - event.start.to_time > 86399
            end
            bookings.push(booking)
        }
        bookings
	rescue Exception => msg  
	    STDERR.puts msg
	    STDERR.flush
	    return []
	end
    end

    def create_booking(room_email:, start_param:, end_param:, subject:, description:nil, current_user:, attendees: nil, timezone:'Sydney', permission: 'impersonation', mailbox_location: 'user')
        STDERR.puts "CREATING NEW BOOKING IN LIBRARY"
        STDERR.puts "room_email is #{room_email}"
        STDERR.puts "start_param is #{start_param}"
        STDERR.puts "end_param is #{end_param}"
        STDERR.puts "subject is #{subject}"
        STDERR.puts "description is #{description}"
        STDERR.puts "current_user is #{current_user}"
        STDERR.puts "attendees is #{attendees}"
        STDERR.puts "timezone is #{timezone}"
        STDERR.flush
        # description = String(description)
        attendees = Array(attendees)


        booking = {}

        # Allow for naming of subject or title
        booking[:subject] = subject
        booking[:title] = subject
        booking[:location] = Orchestrator::ControlSystem.find_by_email(room_email).name


        # Set the room email as a resource
        booking[:resources] = [{
            attendee: {
                mailbox: {
                    email_address: room_email
                }
            }
        }]

        # start_object = Time.at(start_param.to_i)
        # end_object = Time.at(end_param.to_i)

        start_object = ensure_ruby_date(start_param.to_i)
        end_object = ensure_ruby_date(end_param.to_i)
        

        # Add start and end times
        booking[:start] = start_object.utc.iso8601.chop
        booking[:end] = end_object.utc.iso8601.chop

        # Add the current user passed in as an attendee
        mailbox = { email_address: current_user.email }
        mailbox[:name] = current_user.name if current_user.name
        booking[:required_attendees] = [{
            attendee: { mailbox:  mailbox }
        }]

        # Add the attendees 
        attendees.each do |attendee|
        # If we don't have an array of emails then it's an object in the form {email: "a@b.com", name: "Blahman Blahson"}
            if attendee.class != String
                attendee = attendee['email']
            end
            booking[:required_attendees].push({
                attendee: { mailbox: { email_address: attendee}}
            })
        end

        # Add the room as an attendee (it seems as if some clients require this and others don't)
        booking[:required_attendees].push({ attendee: { mailbox: { email_address: room_email}}})
        booking[:body] = description

        # A little debugging
        STDERR.puts "MAKING REQUEST WITH"
        STDERR.puts booking
        STDERR.flush

        if mailbox_location == 'user'
            mailbox = current_user.email
        elsif mailbox_location == 'room'
            mailbox = room_email
        end

        # Determine whether to use delegation, impersonation or neither
        if permission == 'delegation'
            folder = @ews_client.get_folder(:calendar, { act_as: mailbox })
        elsif permission == 'impersonation'
            @ews_client.set_impersonation(Viewpoint::EWS::ConnectingSID[:SMTP], mailbox)
            folder = @ews_client.get_folder(:calendar)
        elsif permission == 'none' || permission.nil?   
            folder = @ews_client.get_folder(:calendar)
        end

        # Create the booking and return data relating to it
        appointment = folder.create_item(booking)
        {
            id: appointment.id,
            start: start_param,
            end: end_param,
            attendees: attendees,
            subject: subject
        }
    end

    def update_booking(booking_id:, room_email:nil, start_param:nil, end_param:nil, subject:nil, description:nil, current_user:nil, attendees: nil, timezone:'Sydney', permission: 'impersonation', mailbox_location: 'user')

        event = @ews_client.get_item(booking_id)
        booking = {}

        # Add attendees if passed in
        attendees = Array(attendees)
        attendees.each do |attendee|
            if attendee.class != String
                attendee = attendee['email']
            end
            booking[:required_attendees] ||= []
            booking[:required_attendees].push({
                attendee: { mailbox: { email_address: attendee}}
            })
        end if attendees && !attendees.empty?

        # Add subject or title
        booking[:subject] = subject if subject
        booking[:title] = subject if subject

        # Add location
        booking[:location] = Orchestrator::ControlSystem.find_by_email(room_email).name if room_email

        # Add new times if passed
        booking[:start] = Time.at(start_param.to_i / 1000).utc.iso8601.chop if start_param
        booking[:end] = Time.at(end_param.to_i / 1000).utc.iso8601.chop if end_param

        if mailbox_location == 'user'
            mailbox = current_user.email
        elsif mailbox_location == 'room'
            mailbox = room_email
        end

        if permission == 'impersonation'
            @ews_client.set_impersonation(Viewpoint::EWS::ConnectingSID[:SMTP], mailbox)
        end
        
        new_booking = event.update_item!(booking)


        {
            id: new_booking.id,
            start: new_booking.start,
            end: new_booking.end,
            attendees: new_booking.required_attendees,
            subject: new_booking.subject
        }
    end

    def delete_booking(booking_id:, mailbox:)
        @ews_client.set_impersonation(Viewpoint::EWS::ConnectingSID[:SMTP], mailbox)  
        booking = @ews_client.get_item(booking_id)
        booking.delete!(:recycle, send_meeting_cancellations: "SendOnlyToAll")
        200
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
