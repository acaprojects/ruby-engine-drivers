
// Will be defined in the root zone, like buildings and levels
// "tracking_system": "sys-desk-tracking"
//
win.control.systems['sys-desk-tracking'] = {
    DeskManagement: [{
        $desk_details: (desk_id: string) => {
            return this[desk_id];
        },

        $desk_usage: (building: string, level: string) => {
            return this[`${building}:${level}`] + this[`${building}:${level}:reserved`];
        },

        // The reservation settings
        hold_time: 300,     // 5min in seconds for example
        reserve_time: 7200, // 2 hours in seconds

        // Desks in use
        "level_id": ["desk1", "desk2", "desk4", "desk5", "desk6", "desk7"],

        // People sitting at reserved desks when they shouldn't be
        "level_id:clashes": ["desk2", "desk7"],

        // Reserved desks that are not in use but otherwise reserved
        "level_id:reserved": ["desk3", "desk8"],

        // Desks that the user can click to manually check in
        "level_id:manual_checkin": ["desk9"],

        // Number of free desks on the level
        "level_id:desk_count": 30,
        "level_id:occupied_count": 6,
        "level_id:free_count": 24,

        // If connected==false, reserved_by==your/current user, user.reserve_time < global.reserve_time and user.reserve_time + unplug_time < time.now
        //   then prompt user to reserve or release desk.
        // If conflict=true then notify that your sitting at someone elses desk
        "user_id": {
            "ip": "10.10.10.10",      // Connected devices IP address -- null if connected == false
            "mac": "12:34:45:34:67",  // Connected devices MAC address
            "connected": true,
            "desk_id": "desk1",
            "username": "username",   // only set if connected==true and should be your username in this case
            "reserved": true,         // True if reservation valid
            "reserved_by": "username",// The user who "owns" the desk might not be you - might indicate a clash but reservation might have expired
            "conflict": false,        // Only true if the reservation is valid and the desk isn't owned by you
            "reserve_time": 300,      // should only ever be set to either hold_time or reserve_time
            "unplug_time": 1511307676 // unix epoch in seconds
        },

        /*

            reserved == false (if connected == false && unplug_time + reserve_time > time.now)

            If the reserve_time == 0 then the user released the desk (both manual and auto desks)
                   reserve_time > 0  then the reservation timed out
             
            released_at == user initiated checkout time (this field may not be set)
            unplug_time + reserve_time == reservation timeout time

        */

        // Accepts a desk from the "level_id:manual_checkin" array and checks the user in
        $manual_checkin: (desk_id: string, level_id?: string) => {
            self["level_id"] = self["level_id"].concat([desk_id]);
            self["level_id:clashes"] = self["level_id:clashes"].concat([desk_id]);
            self["level_id:occupied_count"] += 1;
            self["level_id:free_count"] -= 1;
        },

        // Will reserve the desk that is indicated above (batch updated - up to 1min latency)
        $reserve_desk: () => {
            // Just ignore the current version of the binding and hide the message
            // The next update of the binding should be accurate
        },
        $cancel_reservation: () => {
            // Just ignore the current version of the binding and hide the message
            // The next update of the binding should be accurate
        }
    }]
};
