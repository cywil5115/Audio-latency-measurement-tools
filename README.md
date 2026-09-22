Dante NMP Measurement Plugins

Custom REAPER plugins developed as part of a master's thesis on Networked Music Performance (NMP) using the Dante Audio-over-IP protocol.

The project focuses on real-time measurement and monitoring of audio latency in networked music performance systems.

Overview

The plugins were developed to enable continuous, sample-accurate latency measurements in a round-trip configuration. Two measurement methods were implemented:

MLS Monitor — latency measurement based on Maximum Length Sequence (MLS) correlation.

Adaptive Timecode — a custom adaptive timecode inspired by SMPTE LTC, designed for continuous latency and stability monitoring.

Both tools were implemented as custom REAPER plugins and can be used to evaluate the behaviour of networked audio paths under different conditions.

Project Context

The plugins were developed and tested as part of a pilot deployment connecting Gdańsk University of Technology and the Academy of Music in Gdańsk through the Tricity Academic Computer Network (TASK).

The system used Dante Audio-over-IP for audio transmission and was evaluated in terms of:

one-way and round-trip latency,

long-term timing stability,

artificial delay linearity,

audio buffer size,

additional network load.

The two measurement methods were validated against each other and against Room EQ Wizard (REW).

Results

The tested network path achieved a measured one-way latency of approximately 1.6 ms, including analogue-to-digital and digital-to-analogue conversion, with a Dante latency setting of 250 µs.

The measurements remained stable over extended sessions, with no lost timecode frames. The two custom measurement methods agreed to single-sample resolution, while the independent REW measurement confirmed the results within 13 µs.

Repository Contents

This repository contains the source code and project files for the custom REAPER plugins developed during the project.

Note: The plugins are research/prototype software developed for experimental networked music performance and latency measurement.

Thesis

The software was developed as part of a master's thesis investigating the practical feasibility of Dante-based networked music performance over an academic network.

Full thesis title:

Pilot Implementation of a Networked Music Performance System Using the Dante Audio-over-IP Protocol
