# LM-073 runtime evidence deferred to H9

No application, XCUITest, ScreenCaptureKit, Apple ImageIO, VideoToolbox, or hardware-media
runtime was executed on this laptop. The safe evidence proves the Activity projection,
calendar/DST model, accessibility strings, navigation handoff model, source composition, and
compile closure only. It is not a substitute for installed runtime evidence.

H9 must exercise the installed signed application on the isolated validation Mac and record:

- day and week range interaction across normal, spring-forward, and fall-back fixtures;
- visual cells and the accessibility table reporting the same minutes;
- explicit missing-hour and first/repeated-hour labels through VoiceOver;
- keyboard access to range/date controls and hourly cells; and
- an hourly cell opening Timeline at the exact real elapsed interval.

Any mismatch leaves LM-073 blocked.
