# Third-party licences

| What | Where in this repo | Licence |
|---|---|---|
| AutoGrade's own code, docs and tooling | everything not listed below | **PolyForm Noncommercial 1.0.0** (`LICENSE`, official text unchanged, from https://github.com/polyformproject/polyform-licenses at tag 1.0.0) |
| Code ported from AdaInt | `research/oracle/ailut.py` (model classes, kernel wrappers), `Core/Shaders/Grade.metal` (`ailut_eval`, `lower_bound_clamped`, `lut_apply`) | Apache-2.0, Copyright (c) MMEditing Authors (`Resources/Models/AdaInt-LICENSE.txt`); each file says what was changed |
| AdaInt code and pretrained weights (converted to CoreML) | `Resources/Models/AdaIntFiveK.mlpackage` | Apache-2.0 (`Resources/Models/AdaInt-LICENSE.txt`) for the upstream code; the weights were trained on MIT-Adobe FiveK, see below |
| MIT-Adobe FiveK image `a4739` (listed in FiveK's `filesAdobeMIT.txt`), downscaled, and arrays derived from it | `fixtures/demo_*` | `FiveK-LicenseAdobeMIT.txt` — research use only, no commercial advantage or monetary compensation; this notice must accompany copies |
| MIT-Adobe FiveK images under the Adobe-only licence | none in this repo | `FiveK-LicenseAdobe.txt`, kept for reference: the weights were trained on the whole dataset |

Both FiveK licences (fetched 2026-11-02 from https://data.csail.mit.edu/graphics/fivek/legal/) grant use "solely for your own research purposes" and exclude use "intended for or directed toward commercial advantage or monetary compensation". They speak about the images; whether weights trained on them are bound the same way is not settled by the text. This project treats the weights as research-only, non-commercial.

The project licence covers only what the project owns. It does not relicense the AdaInt-derived portions (Apache-2.0) or the FiveK images (FiveK licences), and the weights stay research-only, non-commercial whatever licence the code carries.
