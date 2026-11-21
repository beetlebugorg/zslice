# Calibrate the filament

A calibration print finds the best value of one setting for your filament and printer. zslice makes the test part on a new plate. The settings of the plate vary the value, so you see each value and can change it.

## Make a test

1. Open the main menu, then **Calibrate**. The search (Ctrl+K) has the same tests.
2. Click a test. zslice adds a new plate with the test part, and a card that tells how to read the print.
3. Print the plate.
4. Open **Calibrate**, then **Use a value of this test…**. Click the button of the best value.

The button sets the value on each plate. zslice keeps it with the filament.

The test uses the filament and the printer of the plate that is active when you click it. Pick the filament first.

## The tests

| Test | The part | What changes | The setting |
|---|---|---|---|
| **Temperature tower** | A tower of blocks, and a thin pillar next to it | Each block prints 5 °C cooler than the block under it, over the usual range of the material | `filament.nozzle_temp` |
| **Retraction test** | Two pillars on a thin base | Each band of 5 mm retracts more than the band under it | `filament.retract_ratio` |
| **Flow test** | Nine flat cubes | Each cube has its own flow: from 20 % less to 20 % more, in steps of 5 % | `filament.flow_ratio` |
| **Pressure advance tower** | A square tower with one wall and no top | Each band of 4 mm has more pressure advance than the band under it | `filament.pressure_advance` |

A tower has a layer range for each step, with its name and its value. Click a band of the layer slider to see it, or change it. The flow test has a part for each step: each part has its own flow, and its name has the step.

## Read the print

- **Temperature tower**: look for a smooth surface, sharp corners, and few strings to the pillar. Bend the tower: the layers must not break apart. Use the lowest temperature that does all of these well.
- **Retraction test**: look at the strings between the pillars. Use the shortest retraction with no strings.
- **Flow test**: look at the top of each cube. Use the flow of the smoothest top, with no gaps between the lines and no ridges.
- **Pressure advance tower**: look at the corners. Too low gives a bulge at each corner. Too high gives a round corner and a gap after it. Leave out the corner where each layer starts. Use the band with the sharpest corners. If two bands look the same, use the lower value.

For the pressure advance tower, Klipper suggests slow corners during the test: `SET_VELOCITY_LIMIT SQUARE_CORNER_VELOCITY=1 ACCEL=500` before the print. zslice does not change the settings of your printer.

## Labels on the test

With a printer that changes the filament by itself (`machine.filament_change = tool`, for example an AMS), each step has a label with its value, in a second filament. A printer that pauses for a filament change gets no labels: count the steps from the bottom, or from the first part of the plate list.
