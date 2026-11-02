# Third-party licences

| What | Where in this repo | Licence |
|---|---|---|
| AdaInt code and pretrained weights (converted to CoreML) | `Resources/Models/AdaIntFiveK.mlpackage` | Apache-2.0 (`Resources/Models/AdaInt-LICENSE.txt`) for the upstream code; the weights were trained on MIT-Adobe FiveK, see below |
| MIT-Adobe FiveK image `a4739` (listed in FiveK's `filesAdobeMIT.txt`), downscaled, and arrays derived from it | `fixtures/demo_*` | `FiveK-LicenseAdobeMIT.txt` — research use only, no commercial advantage or monetary compensation; this notice must accompany copies |
| MIT-Adobe FiveK images under the Adobe-only licence | none in this repo | `FiveK-LicenseAdobe.txt`, kept for reference: the weights were trained on the whole dataset |

Both FiveK licences (fetched 2026-11-02 from https://data.csail.mit.edu/graphics/fivek/legal/) grant use "solely for your own research purposes" and exclude use "intended for or directed toward commercial advantage or monetary compensation". They speak about the images; whether weights trained on them are bound the same way is not settled by the text. This project treats the weights as research-only, non-commercial.
