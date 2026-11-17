# Projects

A project is a repository with a `printdeck.yml` file at its root. The file lists the parts to print. Each part has its model files, a count, a printer, a Cura profile, a material, and Cura settings. printdeck uses the same file for its builds from GitHub.

## Open a project

In the web app, open the **Project** tab in the panel, then do one of these:

- Type `owner/repo`, or the address of a repository on github.com, and click **Open**. An address with `/tree/<branch>` opens that branch. The repository must be public.
- Click **Open a folder…**, and choose the folder of the repository on your computer.

The tab shows the plates of the project, and its parts.

## The parts

Each part has a check box and a count. The count is the number of copies of each file of the part. Clear the check box to leave the part out. The plates change at once.

## The plates

zslice puts the chosen parts on plates:

- The parts with the same printer, profile, material, and plate settings share a plate. A plate setting is a setting that zslice keeps for the whole plate, for example the support or the brim. The infill, the walls, and the seam can differ from part to part on one plate.
- A part with `alone: true` gets a plate of its own.
- A part with variants (for example a fine and a fast quality) is one part for each variant.

Click **Open** on a plate. zslice then does these steps:

1. It reads the Cura profile stack of the plate from `profiles/<folder>/` (its `cura.json`), with the profile and the material of the parts.
2. It sets the plate settings of the parts.
3. It puts the copies of the files on the bed, each part with its own settings, and arranges them.
4. It slices the plate.

Then export the G-code, or send it to your printer. If you have a printer with the name of the printer of the plate (for example `taz`), zslice chooses it for the print.

A plate that has no Cura stack is a resin plate. zslice does not slice resin plates yet.

## The status of a plate

Each plate has a status: **To print**, **Printing**, **Printed**, or **Failed**. Set it with the list on the plate. A print that you send to the printer from the plate sets **Printing**. The tab counts the printed plates.

The project, the counts, and the status stay in your browser after a reload. A GitHub project gets its files again from GitHub. A folder must be opened again, because the browser forgets the files of a folder.

## printdeck.yml

```yaml
project: robot
parts:
  - name: Feet
    group: Legs
    files: [models/foot.stl]
    count: 4
    printer: taz
    profile: taz-workhorse-se/pla-0.20-standard   # profiles/<folder>/ and a profile of its cura.json
    material: roll-4                               # a material of that cura.json
    settings: {support_enable: false, adhesion_type: brim, brim_line_count: 10}
  - name: Tower
    files: [models/tower.stl]
    printer: taz
    profile: taz-workhorse-se/pla-0.20-standard
    material: roll-4
    alone: true
    variants:
      - name: fine
        profile: taz-workhorse-se/pla-0.10-fine
      - name: fast
        settings: {infill_sparse_density: 10}
```

The settings use the names of Cura. zslice converts them with the map of its Cura import. A setting that zslice cannot use stops the load of the plate, with the reason.

## Privacy

To open a GitHub project, the app reads the repository from `api.github.com` and `raw.githubusercontent.com`. It sends no login and no data of yours. See [Privacy](../../privacy/).
