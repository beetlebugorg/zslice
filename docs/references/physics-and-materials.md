# Physics and materials

The physics, the material data, and the papers behind the print simulation, the bond of the first layer, and the rigid body placement.

## Algorithms, formats, and conventions

### Euler buckling and cantilever bend

```ref
kind: idea
source: Timoshenko and Gere
license: Textbook physics
files: src/tree_support.zig, src/support.zig
area: support
summary: The least radius of a tree branch at each height (the bend rule and the buckling rule), and the foot radius (the pull of the nozzle push on a disk on the bed).
```

Euler buckling of a column fixed at one end and free at the other (P = pi^2 E I / (4 L^2)), and the bend of a cantilever under an end load (F L^3 / (3 E I)), with I = pi r^3 t for a thin-walled tube; standard results of beam theory (for example S. Timoshenko and J. Gere, "Theory of Elastic Stability")

**License:** Textbook physics

**Used in:** `src/tree_support.zig`, `src/support.zig`

**How zslice uses it:** The least radius of a tree branch at each height (the bend rule and the buckling rule), and the foot radius (the pull of the nozzle push on a disk on the bed).

### Polyhedral mass properties

```ref
kind: paper
source: Eberly
license: Paper
link: https://www.geometrictools.com/Documentation/PolyhedralMassProperties.pdf
files: src/rigid.zig
area: physics
summary: The volume, the center of mass, and the inertia tensor of a closed mesh, from the integrals over its faces.
```

David Eberly, "Polyhedral Mass Properties (Revisited)", Geometric Tools, 2002, https://www.geometrictools.com/Documentation/PolyhedralMassProperties.pdf

**License:** Paper

**Used in:** `src/rigid.zig`

**How zslice uses it:** The volume, the center of mass, and the inertia tensor of a closed mesh, from the integrals over its faces.

### Sequential impulses

```ref
kind: paper
source: Catto
license: Paper
link: https://box2d.org/publications/
files: src/rigid.zig
area: physics
summary: The contact solver: sequential impulses with accumulated clamping, friction in the cone of the normal impulse, warm starting, and a Baumgarte push.
```

Erin Catto, "Iterative Dynamics with Temporal Coherence", GDC 2005, and "Fast and Simple Physics using Sequential Impulses", GDC 2006, https://box2d.org/publications/

**License:** Paper

**Used in:** `src/rigid.zig`

**How zslice uses it:** The contact solver: sequential impulses with accumulated clamping, friction in the cone of the normal impulse, warm starting, and a Baumgarte push. No code is copied.

### Bond: PLA and PETG on aluminum

```ref
kind: paper
source: Campos-Jurado et al.
license: Paper
link: https://doi.org/10.3390/polym17162210
files: src/bond.zig
area: physics
summary: The order of the tensile bond of a printed first layer: pull-off tests of PLA (0.40 to 1.71 N/mm²) and PETG (0.62 to about 2 N/mm²) printed on a metal bed.
```

Bond of the first layer: Manuel Campos-Jurado, Óscar Rodríguez-Alabanda, and Guillermo Guerrero-Vacas, "Manufacturing of Polymer-Metal Composite by Fused Filament Fabrication: Adhesion of PLA and PETG on Aluminum", Polymers 17(16):2210, 2025, https://doi.org/10.3390/polym17162210

**License:** Paper (CC BY 4.0); data only

**Used in:** `src/bond.zig`

**How zslice uses it:** The order of the tensile bond of a printed first layer: pull-off tests of PLA (0.40 to 1.71 N/mm²) and PETG (0.62 to about 2 N/mm²) printed on a metal bed. zslice takes 0.3 N/mm² for PLA on PEI, and 1.5 times that for PETG (the ratio of the least values).

### Bond: print speed and temperature

```ref
kind: paper
source: Laumann et al.
license: Paper; data only
link: https://doi.org/10.1080/00218464.2022.2093640
files: src/bond.zig
area: physics
summary: The bond of PLA on three build surfaces reaches 0.56 N/mm² with a tuned first layer.
```

Bond of the first layer: D. Laumann, D. Spiehl, E. Dörsam, and A. Blaeser, "Interaction of printing speed and temperature settings on the build plate adhesion of 3D-printed polylactide acid parts", The Journal of Adhesion 99(7):1186-1204, 2023, https://doi.org/10.1080/00218464.2022.2093640

**License:** Paper; data only

**Used in:** `src/bond.zig`

**How zslice uses it:** The bond of PLA on three build surfaces reaches 0.56 N/mm² with a tuned first layer. zslice takes a usual value below it.

### Bond: bed temperature

```ref
kind: paper
source: Snapp, Gongora, and Brown
license: Paper; data only
link: https://doi.org/10.1115/1.4050177
files: src/bond.zig
area: physics
summary: PLA parts on bare glass need 0.27 times the side force to come off as on a polymer film (polyimide) on glass.
```

Bond of the first layer: Kelsey L. Snapp, Aldair E. Gongora, and Keith A. Brown, "Increasing Throughput in Fused Deposition Modeling by Modulating Bed Temperature", Journal of Manufacturing Science and Engineering 143(9):094502, 2021, https://doi.org/10.1115/1.4050177

**License:** Paper; data only

**Used in:** `src/bond.zig`

**How zslice uses it:** PLA parts on bare glass need 0.27 times the side force to come off as on a polymer film (polyimide) on glass. zslice uses this ratio for glass. The test also shows that a taller part comes off with less force: the force acts with a longer lever, as in the model.

### Bond: bed temperature and glass transition

```ref
kind: paper
source: Spoerk et al.
license: Paper; data only
link: https://doi.org/10.1080/14658011.2017.1399531
files: src/bond.zig
area: physics
summary: PLA and ABS reach the same shear-off forces, and the bond grows when the bed is just above the glass transition of the plastic.
```

Bond of the first layer: M. Spoerk, J. Gonzalez-Gutierrez, J. Sapkota, S. Schuschnigg, and C. Holzer, "Effect of the printing bed temperature on the adhesion of parts produced by fused filament fabrication", Plastics, Rubber and Composites 47(1):17-24, 2018, https://doi.org/10.1080/14658011.2017.1399531

**License:** Paper; data only

**Used in:** `src/bond.zig`

**How zslice uses it:** PLA and ABS reach the same shear-off forces, and the bond grows when the bed is just above the glass transition of the plastic. zslice gives ABS the value of PLA.

### Bend of a beam

```ref
kind: idea
source: Timoshenko and Gere
license: Textbook physics
files: src/bond.zig
area: physics
summary: The moment that the bond of the first layer holds about the edge that the part tips over.
```

The bend of a beam: the stress grows in a straight line from the neutral axis, and a section holds a moment sigma I / c; standard beam theory (for example S. Timoshenko and J. Gere, "Mechanics of Materials")

**License:** Textbook physics

**Used in:** `src/bond.zig`

**How zslice uses it:** The moment that the bond of the first layer holds about the edge that the part tips over.

### Position Based Dynamics

```ref
kind: paper
source: Muller et al.
license: Paper
files: src/print_sim.zig
area: physics
summary: The solver of the strands that swing and fall: move each mass by its speed and gravity, correct the places to keep the links, and take the speed from the change of place.
```

Matthias Müller, Bruno Heidelberger, Marcus Hennix, John Ratcliff, "Position Based Dynamics", Journal of Visual Communication and Image Representation 18(2), 2007

**License:** Paper

**Used in:** `src/print_sim.zig`

**How zslice uses it:** The solver of the strands that swing and fall: move each mass by its speed and gravity, correct the places to keep the links, and take the speed from the change of place.

### Long Range Attachments

```ref
kind: paper
source: Kim, Chentanez, Muller-Fischer
license: Paper
files: src/print_sim.zig
area: physics
summary: A strand that fell and is held at both ends: each mass stays within the arc length of each held end.
```

Tae-Yong Kim, Nuttapong Chentanez, Matthias Müller-Fischer, "Long Range Attachments - A Method to Simulate Inextensible Clothing in Computer Games", ACM SIGGRAPH/Eurographics Symposium on Computer Animation (SCA) 2012

**License:** Paper

**Used in:** `src/print_sim.zig`

**How zslice uses it:** A strand that fell and is held at both ends: each mass stays within the arc length of each held end.

### Follow the leader strands

```ref
kind: paper
source: Muller, Kim, Chentanez
license: Paper
files: src/print_sim.zig
area: physics
summary: Follow the leader: a strand held at one end keeps the length of each link in one pass from the held end, with the speed correction (s_damping).
```

Matthias Müller, Tae-Yong Kim, Nuttapong Chentanez, "Fast Simulation of Inextensible Hair and Fur", VRIPHYS 2012

**License:** Paper

**Used in:** `src/print_sim.zig`

**How zslice uses it:** Follow the leader: a strand held at one end keeps the length of each link in one pass from the held end, with the speed correction (s_damping).

### Catenary

```ref
kind: idea
source: General
license: Mathematics
files: src/print_sim.zig
area: physics
summary: The static shape of a soft run held at both ends (a bridge), the solve of a from the span and the arc length, and the tension that makes the hot plastic creep.
```

The catenary: a hanging chain of weight w per length has the shape z = a cosh(x / a) + c, the arc length a sinh(x / a), and the horizontal tension H = a w (Bernoulli, Huygens, and Leibniz, Acta Eruditorum 1691; in texts on statics)

**License:** Mathematics

**Used in:** `src/print_sim.zig`

**How zslice uses it:** The static shape of a soft run held at both ends (a bridge), the solve of a from the span and the arc length, and the tension that makes the hot plastic creep.

### Extensional viscosity

```ref
kind: paper
source: Trouton
license: Paper
files: src/print_sim.zig
area: physics
summary: The extensional viscosity of a Newtonian fluid is 3 times its viscosity: a strand stretches at the rate sigma / (3 eta).
```

Frederick T. Trouton, "On the coefficient of viscous traction and its relation to that of viscosity", Proceedings of the Royal Society A 77, 1906

**License:** Paper

**Used in:** `src/print_sim.zig`

**How zslice uses it:** The extensional viscosity of a Newtonian fluid is 3 times its viscosity: a strand stretches at the rate sigma / (3 eta).

### PLA viscosity (Ingeo 4032D)

```ref
kind: paper
source: Yoo, Jeong, Choi
license: Paper
link: https://doi.org/10.1515/epoly-2021-0071
files: src/print_sim.zig
area: physics
summary: The viscosity of PLA at low shear: about 3037 Pa s at 180 °C and 733 Pa s at 210 °C (Ingeo 4032D).
```

Hyeong-Min Yoo, Su-Yeon Jeong, Sung-Woong Choi, "Analysis of the rheological property and crystallization behavior of polylactic acid (Ingeo Biopolymer 4032D) at different process temperatures", e-Polymers 21(1), 702-709, 2021, https://doi.org/10.1515/epoly-2021-0071

**License:** Paper (data)

**Used in:** `src/print_sim.zig`

**How zslice uses it:** The viscosity of PLA at low shear: about 3037 Pa s at 180 °C and 733 Pa s at 210 °C (Ingeo 4032D). A cross-check of the PLA values of Colón Quintana (2021).

### WLF law

```ref
kind: paper
source: Williams, Landel, Ferry
license: Paper
files: src/print_sim.zig
area: physics
summary: The WLF law with the universal constants (C1 = 17.44, C2 = 51.6 K) near the glass point of PLA, from 1e12 Pa s at the glass point.
```

Malcolm L. Williams, Robert F. Landel, John D. Ferry, "The Temperature Dependence of Relaxation Mechanisms in Amorphous Polymers and Other Glass-forming Liquids", Journal of the American Chemical Society 77(14), 1955

**License:** Paper

**Used in:** `src/print_sim.zig`

**How zslice uses it:** The WLF law with the universal constants (C1 = 17.44, C2 = 51.6 K) near the glass point of PLA, from 1e12 Pa s at the glass point.

### Cooling of a bead

```ref
kind: idea
source: Incropera and DeWitt
license: Textbook methods
files: src/print_sim.zig
area: physics
summary: The cooling of a soft bead, in still air and at the fan.
```

Newton's law of cooling and the lumped heat model (tau = rho c V / (h A)); the Hilpert correlation for a cylinder in cross flow (Nu = C Re^m Pr^(1/3)) and the Churchill-Chu correlation for natural convection, as in F. P. Incropera, D. P. DeWitt, "Fundamentals of Heat and Mass Transfer"

**License:** Textbook methods

**Used in:** `src/print_sim.zig`

**How zslice uses it:** The cooling of a soft bead, in still air and at the fan.

### PLA material values

```ref
kind: data
source: NatureWorks
license: Data
files: src/print_sim.zig
area: physics
summary: The weight, the heat, and the setting of the plastic.
```

PLA material values: density 1.24 g/cm³ and glass point 55 to 60 °C (NatureWorks Ingeo 4043D data sheet); heat capacity of the melt about 1.8 kJ/(kg K)

**License:** Data

**Used in:** `src/print_sim.zig`

**How zslice uses it:** The weight, the heat, and the setting of the plastic.

### PLA zero-shear viscosity

```ref
kind: paper
source: Patti et al.
license: Paper
link: https://doi.org/10.3390/chemengineering7010001
files: src/print_sim.zig
area: physics
summary: Two commercial PLA filaments have a zero-shear viscosity of about 1e4 Pa s at 170 °C. A cross-check of the PLA values of Colón Quintana (2021).
```

Antonella Patti, Stefano Acierno, Gianluca Cicala, Domenico Acierno, "Predicting the Printability of Poly(Lactide) Acid Filaments in Fused Deposition Modeling (FDM) Technology: Rheological Measurements and Experimental Evidence", ChemEngineering 7(1), 1, 2022, https://doi.org/10.3390/chemengineering7010001

**License:** Paper (data), CC BY 4.0

**Used in:** `src/print_sim.zig`

**How zslice uses it:** Two commercial PLA filaments have a zero-shear viscosity of about 1e4 Pa s at 170 °C. A cross-check of the PLA values of Colón Quintana (2021).

### Melting in FFF (materials)

```ref
kind: paper
source: Colon Quintana
license: Thesis
link: https://additive-mfg.me.wisc.edu/wp-content/uploads/sites/950/2022/04/main.pdf
files: src/print_sim.zig
area: physics
summary: The materials of the simulated print.
```

José Luis Colón Quintana, "Understanding Melting in Fused Filament Fabrication Process", PhD preliminary report, University of Wisconsin-Madison, 2021, https://additive-mfg.me.wisc.edu/wp-content/uploads/sites/950/2022/04/main.pdf

**License:** Thesis (data)

**Used in:** `src/print_sim.zig`

**How zslice uses it:** The materials of the simulated print. PLA (MatterHackers): zero-shear viscosity 3546 Pa s at 200 °C, Arrhenius with 80.6 kJ/mol, glass point 58.9 °C, density 1250 kg/m³, heat capacity 1800 J/(kg K), conductivity 0.163 W/(m K). ABS (MG94): 13 250 Pa s at 200 °C, WLF with C1 = 3.938 and C2 = 128.6 K, glass point 104.5 °C, density 1060 kg/m³, heat capacity 1381 J/(kg K), conductivity 0.17 W/(m K).

### PETG melt viscosity (US 9,962,913)

```ref
kind: data
source: USPTO
license: Patent
link: https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/9962913
files: src/print_sim.zig
area: physics
summary: The melt viscosity of a PETG: about 28 795 to 48 077 poise (2880 to 4810 Pa s) at 1 rad/s and 220 °C. zslice uses the middle, 3844 Pa s.
```

US patent 9,962,913, "Multilayer film", https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/9962913

**License:** Patent (data)

**Used in:** `src/print_sim.zig`

**How zslice uses it:** The melt viscosity of a PETG: about 28 795 to 48 077 poise (2880 to 4810 Pa s) at 1 rad/s and 220 °C. zslice uses the middle, 3844 Pa s.

### PETG data sheet

```ref
kind: data
source: 3D Universe
license: Data sheet
link: https://shop3duniverse.com/cdn/shop/t/134/assets/3D_Universe_PETG_filament_TDS.pdf
files: src/print_sim.zig
area: physics
summary: PETG: glass point 80 °C, density 1.29 g/cm³.
```

3D Universe, "PETG 3D Filament Data Sheet", https://shop3duniverse.com/cdn/shop/t/134/assets/3D_Universe_PETG_filament_TDS.pdf

**License:** Data sheet

**Used in:** `src/print_sim.zig`

**How zslice uses it:** PETG: glass point 80 °C, density 1.29 g/cm³.

### Bridge sag of PLA

```ref
kind: paper
source: Yang et al.
license: Paper
link: https://doi.org/10.1088/1755-1315/772/1/012069
files: src/print_sim.zig, src/app/sim_calib.zig, tools/calib/
area: physics
summary: PLA bridges (0.4 mm nozzle, 0.2 mm layers, fan on): almost no visible sag below 33 mm, loose strands under the deck past 37 mm, and about 1 to 1.5 mm of sag in a 35 mm deck.
```

Chun Yang, Jianhua Liu, Xiaohui Ao, Huanxiong Xia, "Experimental Study on the Dimension Error of Bridged Structures Printed by Fused Deposition Modeling", IOP Conf. Series: Earth and Environmental Science 772, 012069, 2021, https://doi.org/10.1088/1755-1315/772/1/012069

**License:** Paper (data), CC BY 3.0

**Used in:** `src/print_sim.zig`, `src/app/sim_calib.zig`, `tools/calib/`

**How zslice uses it:** PLA bridges (0.4 mm nozzle, 0.2 mm layers, fan on): almost no visible sag below 33 mm, loose strands under the deck past 37 mm, and about 1 to 1.5 mm of sag in a 35 mm deck. The limit of `fail_drop` and the targets of the bridge calibration test.

### Critical overhang angle

```ref
kind: paper
source: Mititelu et al.
license: Paper
link: https://doi.org/10.1002/masy.70376
files: src/app/sim_calib.zig
area: physics
summary: PLA overhangs keep their shape up to about 25 degrees from horizontal (65 from vertical).
```

Mititelu et al., "Investigation of the Critical Overhang Angle in Fused Filament Fabrication Technology", Macromolecular Symposia, 2026, https://doi.org/10.1002/masy.70376 (abstract)

**License:** Paper (data)

**Used in:** `src/app/sim_calib.zig`

**How zslice uses it:** PLA overhangs keep their shape up to about 25 degrees from horizontal (65 from vertical). The target of the overhang calibration test.

### Overhang threshold and temperature

```ref
kind: paper
source: Jiang, Xu, Stringer
license: Paper
link: https://doi.org/10.1016/j.procir.2019.04.047
files: src/app/sim_calib.zig
area: physics
summary: The 45 degree rule for overhangs, and its change with the fan, the speed, and the temperature.
```

Jingchao Jiang, Xun Xu, Jonathan Stringer, "Effect of Extrusion Temperature on Printable Threshold Overhang in Additive Manufacturing", Procedia CIRP 81, 2019, https://doi.org/10.1016/j.procir.2019.04.047; and Jiang, Stringer, Xu, Zhong, International Journal of Computer Integrated Manufacturing 31(10), 2018, https://doi.org/10.1080/0951192X.2018.1466398 (abstracts)

**License:** Paper

**Used in:** `src/app/sim_calib.zig`

**How zslice uses it:** The 45 degree rule for overhangs, and its change with the fan, the speed, and the temperature.
