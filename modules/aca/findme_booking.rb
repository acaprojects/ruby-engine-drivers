module Aca; end

# NOTE:: Requires Settings:
# ========================
# room_alias: 'rs.au.syd.L16Aitken',
# building: 'DP3',
# level: '16'

class Aca::FindmeBooking
    include ::Orchestrator::Constants


    descriptive_name 'Findme Room Bookings'
    generic_name :Bookings
    implements :logic

    
    # The room we are interested in
    default_settings update_every: '5m'


    def on_load
        @day_checked = [0, 1, 2, 3, 4, 5, 6]
        @day_checking = [nil, nil, nil, nil, nil, nil, nil]

        on_update
    end

    def on_update
        self[:building] = setting(:building)
        self[:level] = setting(:level)
        self[:room] = setting(:room)

        fetch_bookings
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = schedule.every(setting(:fetch_bookings) || '5m', method(:fetch_bookings))
    end


    def fetch_bookings(*args)
        # Fetches bookings from now to the end of the day
        findme = system[:FindMe]
        findme.meetings(self[:building], self[:level]).then do |raw|
            promises = []
            bookings = []

            raw.each do |value|
                bookings << value if value[:ConferenceRoomAlias] == self[:room]
            end

            bookings.each do |booking|
                username = booking[:BookingUserAlias]
                if username
                    promise = findme.users_fullname(username)
                    promise.then do |name|
                        booking[:owner] = name
                    end
                    promises << promise
                end
            end

            thread.all(*promises).finally do
                # UI will assume these are sorted
                self[:today] = bookings
            end
        end
    end

    def bookings_for(day)
        now = Time.now
        day_num = day.to_i
        current = now.wday
        
        if day_num != now.wday && @day_checked[day_num] < (now - 5.minutes)
            promise = @day_checking[day_num]
            return promise if promise

            # TODO:: Calculate the start and end times for this particular day

            # Clear the old data
            symbol = :"day_#{day_num}"
            self[symbol] = nil

            # We are looking for bookings on another day
            promise = system[:FindMe].meetings(self[:building], self[:level])
            @day_checking[day_num] = promise
            promise.then do |bookings|
                self[symbol] = bookings[self[:room]]
            end
            promise.finally do
                @day_checking[day_num] = nil
            end
        end
    end

    # TODO:: Provide a way to indicate if this succeeded or failed
    def schedule_meeting(user, starting, ending, subject)
        system[:FindMe].schedule_meeting(user, self[:room], starting, ending, subject)
    end
end
