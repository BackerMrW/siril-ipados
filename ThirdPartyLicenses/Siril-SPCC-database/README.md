# siril-spcc-database

## How to help

The spcc-database is designed to store JSON files of osc/monochrome sensors and 
filters available in the market. Its primary objective is to gather extensive 
data, fostering collaboration within the community.

We greatly value community contributions and encourage active participation. We 
are in need of data spanning ideally from 300nm to 1100nm. Software tools can be 
employed to extract curves/charts found online, and contacting manufacturers 
directly for data is also an option.

Please note that we do not include narrowband filters. These highly specific 
filters are synthesized in Siril, ensuring precision, which applies to 
duonarrowband filters as well.

To streamline the process, kindly open a Merge Request for each new dataset 
added. This facilitates easier review and ensures seamless integration. Thank 
you for your contributions!


## 🆕 Online Submission Wizard (Beta)

For a streamlined experience, you can now use our **[Online Submission Wizard](https://siril-contrib-doc.readthedocs.io/en/latest/SPCCDatabase.html)** directly in your browser! This tool allows you to:

- **📄 Create JSON files** from CSV data extracted with tools like [WebPlotDigitizer](https://apps.automeris.io/wpd4/)
- **🔍 Validate your data** and automatically remove duplicates
- **📈 Generate spectral response plots** to visualize your data
- **💾 Download** cleaned files and plots ready for submission

No Python installation required! Simply upload your CSV data and follow the guided process.

### Traditional Method (Python Scripts)

If you prefer working locally, you can still use the Python scripts in the `utils/` folder for data processing and validation.

## JSON File Template

Here is a template for the json files used in spcc-database-schema:

```
[
  {
    "model": "sensor model / filter set",
    "name": "sensor / filter name",
    "type": "MONO_SENSOR | OSC_SENSOR | MONO_FILTER | OSC_FILTER | OSC_LPF | WB_REF" (delete as appropriate),
    "dataQualityMarker": 1 - 5 (delete as appropriate),
    "dataSource": "Describe where the data came from",
    "manufacturer": "Manufacturer name",
    "version": 1,
    "channel": "RED | GREEN | BLUE | LUM" (delete as appropriate),
    "wavelength": [Comma separated array of wavelengths],
    "values": [Comma separated array of values]
  }
]
```

Here is an example of data for an OSC sensor:
![alt text](https://free-astro.org/download/SPCC_data_seestar_2024-03-19T09.38.24.png)

## Notes about the JSON file
There are several things to note:

* Definition of the dataQualityMarker field is as follows:

  1. Data of unknown provenance. Data with this quality marker will not generally
     be accepted for the siril-spcc-database repository.
  2. Data scanned from OEM or other reputable plots in image format.
  3. Lower resolution tabulated data provided by the OEM, or academic data relating
     to ideal standard filter transmittance (e.g. generic standard photometric
     filters).
  4. High resolution (no nore than 2nm spacing) tabulated data provided by the
     OEM.
  5. Data specific to your own filter which you have personally calibrated using
     appropriate equipment. This is the highest possible quality marker and will
     never be given to .json files in the repository which can only ever be
     generic to an equipment model, not specific to your individual equipment item.
     Note that the actual quality of this data is entirely dependent on the
     quality of your calibration equipment - the old adage "garbage in, garbage
     out" applies.

* The "model" name is primarily used to associate different JSON objects belonging
  to the same OSC sensor or the same mono filter set. For example the names for
  a set of RGB filters might be "Chroma Red", "Chroma Green" and "Chroma Blue"
  and the corresponding "model" might be "Chroma RGB". Similarly for an OSC sensor
  the names might be "ASI2600MC Red", "ASI2600MC Green" and "ASI2600MC Blue" and
  the model might be "ZWO ASI2600MC". In any case the "model" string **must**
  be the same for each object in an associated set.

* The "channel" field is only required if "type" == "OSC_SENSOR" or "MONO_FILTER".
  In the case of an OSC_SENSOR a JSON object should be included in the array for
  each channel response curve, and the channel field is used to indicate which
  is which. The channels should preferably be listed in order R, G, B.

* The "wavelength" array, ideally, should cover at least the range 380nm to 700nm
  or all wavelengths at which there is significant sensor QE or filter
  transmittance. The maximum extent of the Gaia DR3 spectra is 336nm to 1020nm,
  so it is not necessary for SPCC purposes to include data outside this range.

* Values in the "wavelength" object should be monotonically increasing and there
  should be no duplicate wavelength values. Siril will fix these issues but will
  complain, as it indicates a poorly generated data object.

* For filters the "values" object contains transmittance values; for sensors it
  contains quantum efficiency values.

* Various units and ranges can be accommodated: for wavelength, "units" must be
  specified as "angstroms", "nm", "micrometres" or "m". For values, "range" gives
  the nominal maximum value (e.g. for a filter object specifying transmittance as
  percent, "range" should be 100. Siril will scale to a 0.0-1.0 range for
  consistency between data objects.
