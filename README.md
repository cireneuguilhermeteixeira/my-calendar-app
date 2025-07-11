# Calendar App

## Goals

- Schedule meetings.
- Edit/remove appointments.
- Receive suggestions for best times for multiple people.


## Use cases

- Schedule meeting: 

Meeting creator define a date, hour and guests.
Send invite to guests and block their schedule. 


- Edit/Cancel meeting:

Meeting creator can update/delete the date/hour/guests. As soon as it is edited the calendar, people's calendars must be updated, changing the time block and they must be notified as well.


- Suggesting the Best Time:

When suggesting a time, the person should match all the guests and find the next available time for everyone.

# Architeture

<img width="739" height="435" alt="image" src="https://github.com/user-attachments/assets/028f797b-d34f-4e81-ac04-183b27bd8b3d" />


The client will send the request, which will then land on the API gateway. It wouldn't be necessary to use the gateway; we could call the autoscaling group directly. However, I want to store all requests in an SQS queue. These requests will be consumed by the server in order, and the data will be persisted using transactions to avoid inconsistencies. Any error that occurs on the server should be returned to an endpoint on my API gateway, which will send a message to my client that the scheduling was not allowed. Furthermore, the client can see the schedules being changed in real time, thanks to the websocket that sends a message from the server to the client whenever a relevant message occurs.

We're using an ASG to improve availability and prevent application downtime, along with Aurora to ensure the database runs smoothly and scales smoothly.
