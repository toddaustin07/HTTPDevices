# HTTPDevices
SmartThings Edge Driver to create devices with built-in HTTP interface to notify external LAN-based devices/apps of commands and state changes.

Currently supported device types:  **switch, dimmer, momentary button, contact, motion, alarm, temperature+humidity**

Additional device types can be added upon request.

## Use Case

This driver provides an alternative to using my [webrequestor driver](https://github.com/toddaustin07/webrequestor) to send HTTP requests.  Rather than a generic web request driver that must be initiated through automations or manual selection in the mobile app, this driver creates specific device types that can be configured to send HTTP requests associated with that device's specific capabilities.  This can reduce the number of automations needed to achieve the desired results.

### Caveats

The devices created by this driver only *send out* HTTP requests based on commands and state changes.  They do not *receive* HTTP requests from external sources.  If a two-way integration is needed with external devices/apps, then my [MQTTDevices driver](https://github.com/toddaustin07/MQTTDevices) may be a more suitable alternative.

Any body data in the *response* to the HTTP request is ignored.


## Pre-requisites
* SmartThings Hub
* Device or application on the same LAN as the SmartThings hub that accepts HTTP GET/POST/PUT requests

## Installation / Configuration
Install driver using [this channel invite link](https://bestow-regional.api.smartthings.com/invite/Q1jP7BqnNNlL).  Enroll your hub and choose "HTTP Devices V1" from the list of drivers to install.

Once available on your hub, use the SmartThings mobile app to initiate an *Add device / Scan for nearby devices*. A new device called 'HTTP Device Creator' will be found in your hub device room.  Open the device and use the 'Select & Create HTTP Device' button to choose a device type and it will be created and found in your hub device room.

### Device Settings

Each created device has the following settings:

#### Response Timeout
As a default, the driver will timeout if no response is received within 3 seconds. However this can be changed in this Settings option

#### HTTP Requests
In the latest driver version, some devices utilize a single URL plus variable substitution, while others utilize separate URLs for each device state change:
* Dimmer, Temperature+Humidity utilize a single URL with variable substitution
* Contact, Motion, Alarm, Button utilize individual URLs for each possible state
* Switch provides for either method to be used: individual URLs or a single URL using variable substitution (${switch})

In all cases, very long URLs or HTTP bodies are accommodated by provided two configuration fields that are concatenated together.  This may be necessary in cases where the built-in SmartThings field length limitation (about 250 characters) is insufficient.

Each configured request consists of the request URL string plus optional body and headers
##### URL String (required)
The format MUST be as follows:
```
GET:http://<ip:port/path> --OR-- POST:http://<ip:port/path> --OR-- PUT:http://<ip:port/path>
  -- OR --
GET:https://<ip:port/path> --OR-- POST:https://<ip:port/path> --OR-- PUT:https://<ip:port/path>
```
**Notes regarding URL string**
* You must include a valid IP and port number; if you wouldn’t specify a port number in other apps or a browser, then use ‘:80’
* If your URL contains any spaces, use ‘%20’
* URL strings can include any valid HTTP URL string, including parameters in the form of '?parm1=xxx'; For those devices supporting variable substitution, the parameter list typically includes the state variables
* A second 'more URL' field is provided in order to accommodate long strings.  They are simply concatenated together when sent.  Be sure to delete all content from unused 'more URL' fields

##### Body (optional)
Use this field to include additional data with your HTTP request. For those devices supporting variable substitution, the body can contain the state variables.

The format is typically going to be provided as plain text, JSON-formatted, or XML-formatted string, however no syntax or formatting validation is done on this field. If the needed body exceeds the limitations of this field, a second body field 'more Body' is provided which will be contatenated to the first when the request is sent.

Be sure to delete all content from unused body fields.

##### Headers (optional)
Optional headers field *must* be provided as a comma-delimited list in the form of **\<headerkey\>=\<value\>**. For example:

```
Content-Type=text/html, Authorization=mytoken12345
```
    
  * Note the use of the '**=**' (equals) character between headerkey and value; *not* ':' (colon)
  * Spaces are allowed in the value (although not in the headerkey). For example: 'Authorization=Bearer mytokenabcd1234'

If a body is included in the request, then a Content-Type header should be specified.

Content-Length headers are automatically generated and do not need to be specified.

All requests are sent with an Accept: \*/\* by default.  It can be overridden by providing your own Accept header.

Be sure to delete all content from unused Headers fields.
    
#### Motion Devices

These devices have additional Settings options to enable/disable an **auto-revert feature** and to set the auto-revert delay in seconds.  This is useful to automatically have the motion device revert back to 'no motion' after motion detected is turned on.  You can also configure whether or not to send a 'no-motion' HTTP message when the auto-revert is activated.

#### Dimmer (switchLevel) Devices
Since a dimmer device can have a range of values as opposed to a fixed set of values (like on/off for a switch), a single HTTP request is configured to be sent whenever the switchLevel changes, but the request is configured with special variables that will be automatically replaced with the current dimmer-level and/or switch value when sent.  These special variables are: ***${level}*** and ***$(switch)***.  These can be included either as part of the URL string or in the body.

Example URL string:
```
POST:http://192.168.1.105:8765/api/dimmer?state=${level}&switch=${switch}
```
Example body:
```
{"level": ${level}, "switch": ${switch}}
```

#### Temperature+Humidity
Like the Dimmer device, this device can have a range of values so variable substitution is used within a single specified HTTP request.  These special variables are: ***${temperature}*** and ***$(humidity)***


## Usage

Each device behaves like any typical 'virtual' Edge device.  For devices that typically have no specific user controls (such as motion or contact), a switch is included on the Controls screen that can be used to set the current state - either from the mobile app or from automation routines.  In the case of the Temperature+Humidity device, controls are provided to set the temperature and humidity values.

Each device has on its Controls screen an "HTTP Response Code" field which will display the results of the most recent HTTP request sent. Any 2xx response code is considered a successful response.  A 4xx or 5xx response code will appear if the recipient finds any errors or otherwise cannot process the request. 

Automations can be used to control the devices.
