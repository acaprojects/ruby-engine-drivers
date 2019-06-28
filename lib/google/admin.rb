require 'active_support/time'
require 'logger'
require 'googleauth'
require 'google/apis/admin_directory_v1'
require 'google/apis/calendar_v3'

# # Define our errors
# module Google
#     class Error < StandardError
#         class ResourceNotFound < Error; end
#         class InvalidAuthenticationToken < Error; end
#         class BadRequest < Error; end
#         class ErrorInvalidIdMalformed < Error; end
#         class ErrorAccessDenied < Error; end
#     end
# end

class Google::Admin
    TIMEZONE_MAPPING = {
        "Sydney": "AUS Eastern Standard Time"
    }
    def initialize(
            json_file_location: nil,
            scopes: nil,
            admin_email:,
            domain:,
            logger: Rails.logger
        )
        @json_file_location = json_file_location || '/home/aca-apps/ruby-engine-app/keys.json'
        @scopes = scopes || [ 'https://www.googleapis.com/auth/calendar', 'https://www.googleapis.com/auth/admin.directory.user']
        @admin_email = admin_email
        @domain = domain

        admin_api = Google::Apis::AdminDirectoryV1
        @admin = admin_api::DirectoryService.new

        calendar_api = Google::Apis::CalendarV3
        @calendar = calendar_api::CalendarService.new
    end 

    def get_users(q: nil, limit: nil)
        authorization = Google::Auth.get_application_default(@scopes).dup
        authorization.sub = @admin_email if @admin_email
        @admin.authorization = authorization
        options = {
            domain: @domain
        }
        options[:query] = q if q
        options[:max_results] = (limit || 500)
        users = @admin.list_users(options)
        users.users.map do |u| 
            primary_email = nil
            u.emails.each do |email|
                primary_email = email['address'] if email['primary']
            end
            {
                name: u.name.full_name,
                email: primary_email
            }
        end
    end

    def get_user(user_id:)
        authorization = Google::Auth.get_application_default(@scopes).dup
        authorization.sub = @admin_email if @admin_email
        @admin.authorization = authorization
        options = {
            domain: @domain
        }
        options[:query] = user_id
        options[:max_results] = 1
        users = @admin.list_users(options)
        users.users[0]
    end


    def get_available_rooms(room_ids:, start_param:, end_param:)
        authorization = Google::Auth.get_application_default(@scopes).dup
        authorization.sub = @admin_email if @admin_email
        @calendar.authorization = authorization
        now = Time.now
        start_param = ensure_ruby_date((start_param || now))
        end_param = ensure_ruby_date((end_param || (now + 1.hour)))

        freebusy_items = []
        room_ids.each do |room|
            freebusy_items << Google::Apis::CalendarV3::FreeBusyRequestItem.new(id: room)
        end

        options = {
            items: freebusy_items,
            time_min: start_param,
            time_max: end_param
        }
        freebusy_request = Google::Apis::CalendarV3::FreeBusyRequest.new options

        events = @calendar.query_freebusy(freebusy_request).calendars
        events.delete_if {|email, resp| !resp.busy.empty?  }
    end

    def delete_booking(room_id:, booking_id:)
        authorization = Google::Auth.get_application_default(@scopes).dup
        authorization.sub = @admin_email if @admin_email
        @calendar.authorization = authorization
        @calendar.delete_event(room_id, booking_id)
    end

    def get_bookings(email:, start_param:nil, end_param:nil)
        authorization = Google::Auth.get_application_default(@scopes).dup
        authorization.sub = @admin_email if @admin_email
        @calendar.authorization = authorization
        if start_param.nil?
            start_param = DateTime.now
            end_param = DateTime.now + 1.hour
        end

        events = @calendar.list_events(email, time_min: start_param.iso8601, time_max: end_param.iso8601).items
        events.map do |event|
            {
                start_date: event.start.date_time.to_i * 1000,
                end_date: event.end.date_time.to_i * 1000,     
                Start: event.start.date_time.utc.iso8601,
                End: event.end.date_time.utc.iso8601,
                subject: event.summary,
                title: event.summary,
                description: event.description,
                attendees: event.attendees.map {|a| {name: a.display_name, email: a.email} },
                id: event.id
            }
        end
    end

    def create_booking(room_email:, start_param:, end_param:, subject:, description:nil, current_user:, attendees: nil, recurrence: nil, timezone:'Sydney')
        authorization = Google::Auth.get_application_default(@scopes).dup
        authorization.sub = @admin_email if @admin_email
        @calendar.authorization = authorization
        description = String(description)
        attendees = Array(attendees)

        # Get our room
        room = Orchestrator::ControlSystem.find_by_email(room_email)

        # Ensure our start and end params are Ruby dates and format them in Graph format
        start_object = ensure_ruby_date(start_param)
        end_object = ensure_ruby_date(end_param)
        start_param = Google::Apis::CalendarV3::EventDateTime.new({ date_time: start_object, timezone: timezone })
        end_param = Google::Apis::CalendarV3::EventDateTime.new({ date_time: end_object, timezone: timezone })

        event_params = {
            start: start_param,
            end: end_param,
            summary: subject,
            description: description
        }
    
        # Add the attendees
        attendees.map!{|a|
            attendee_options = {
                display_name: a[:name],
                email: a[:email]
            }
            Google::Apis::CalendarV3::EventAttendee.new(attendee_options)
        }

        # Add the room as an attendee
        room_attendee_options = {
            resource: true,
            display_name: room.name,
            email: room_email,
            response_status: 'accepted'
        }

        attendees.push(Google::Apis::CalendarV3::EventAttendee.new(room_attendee_options))

        event_params[:attendees] = attendees

        # Add the current_user as an attendee
        event_params[:creator] = Google::Apis::CalendarV3::Event::Creator.new({ display_name: current_user.name, email: current_user.email })

        event = Google::Apis::CalendarV3::Event.new event_params

        @calendar.insert_event(room_email, event)
    end


    # Takes a date of any kind (epoch, string, time object) and returns a time object
    def ensure_ruby_date(date) 
        if !(date.class == DateTime)
            if string_is_digits(date)

                # Convert to an integer
                date = date.to_i

                # If JavaScript epoch remove milliseconds
                if date.to_s.length == 13
                    date /= 1000
                end

                # Convert to datetimes
                date = DateTime.parse(Time.at(date).to_s)
            else
                date = DateTime.parse(date.to_s)                
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
