# The print as it forms

See the plastic as the printer lays it. A bridge sags. A slab over the air falls in strands, and the next layers print on them.

![A bridge 80 mm long prints and sags. Then a slab prints over the air on each side of a post, and its plastic falls in strands](../img/sim-forms.webp "The replay of two prints with support off, with the simulation on.")

## See it

1. Slice the part.
2. Wait a moment. zslice simulates the plastic of each slice in the background. When the simulation is done, the view shows the simulated plastic in place of the planned lines.
3. Press ▶ on the dock to replay the print, or drag the layer slider.
4. Open the details of the print: click the print time on the dock. When the plastic falls or droops, a note says at which layer the print fails, or how far the plastic droops. With support off, the note has a **Turn on support** button.

A change slices the part again, and the simulation runs again on the new slice. While you drag a part, the view shows the plan. The simulated plastic shows after a short pause.

## Show the plan

- Open the colors menu in the tool strip. Its last item is **Show the plan**. Click it to see the planned lines.
- Click the same item again, now **Show the print as it forms**, to see the simulated plastic.
- Press `/` and type "as it forms". The action **The print as it forms** switches between the two views.

## A bridge sags

![The bridge at the end of the print: the deck hangs down in the middle, between the two piers](../img/sim-bridge.webp "An 80 mm bridge with support off: the first lines of the deck sag between the piers.")

- The plastic between two held ends hangs as a chain. It creeps down while it is hot, and stops as it cools.
- More fan cools it faster, so it sags less. A hotter nozzle or a longer span sags more.

## A slab in the air falls

![The slab at the end of the print: strands of plastic hang and fall from both sides of the post](../img/sim-slab.webp "A slab 20 mm out into the air on each side of a post: the plastic falls in strands.")

- Plastic with no hold under it swings and falls, until it touches the bed or solid plastic.
- The next layers print on the strands, where they set.
- Turn on support, or turn the part, and slice again.

## What it knows

| It knows | It does not know yet |
|---|---|
| The time at which each bit of plastic leaves the nozzle | Strands that touch each other |
| How the plastic cools, in still air and with the fan | A set strand that bends later under the layers on it |
| How thick PLA, PETG, and ABS get as they cool, until they set | Data for other materials: ASA and HIPS simulate as ABS, PET and PCTG as PETG, and the rest as PLA |
| Where the bed and earlier layers hold the plastic | |
| A strand that hangs from one end swings and falls | |

The material comes from the filament type (`filament.material`). When the simulation has no data for the filament, the note says which material it used.

A 3DBenchy simulates in about 1.5 s on one core. The physics, with the numbers, is in [The print simulation](../internals/print-sim.md).

## Where to go next

- → [Add support](support.md): hold up what falls.
- → [Check the print](check.md): the list of overhangs and bridges.
- → [The best features](features.md): parts with real physics, and more.
