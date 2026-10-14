// SPDX-License-Identifier: GPL-3.0-or-later
// Independently authored virtual printer for tests; never a production profile.
typedef struct { cmsHTRANSFORM rgb_to_lab, lab_to_rgb; } ProofFixtureSamplers;
static cmsInt32Number proof_fixture_forward(const cmsUInt16Number input[], cmsUInt16Number output[], void *user) {
    ProofFixtureSamplers *samplers = user;
    double rgb[3]; cmsDoTransform(samplers->lab_to_rgb, input, rgb, 1);
    for (int c = 0; c < 3; c++) rgb[c] = fmin(1, fmax(0, rgb[c]));
    double black = 1 - fmax(rgb[0], fmax(rgb[1], rgb[2]));
    for (int c = 0; c < 3; c++) output[c] = lround((black < 1 ? (1 - rgb[c] - black) / (1 - black) : 0) * 65535);
    output[3] = lround(black * 65535); return 1;
}
static cmsInt32Number proof_fixture_reverse(const cmsUInt16Number input[], cmsUInt16Number output[], void *user) {
    ProofFixtureSamplers *samplers = user;
    double rgb[3], black = input[3] / 65535.0;
    for (int c = 0; c < 3; c++) rgb[c] = (1 - input[c] / 65535.0) * (1 - black);
    cmsDoTransform(samplers->rgb_to_lab, rgb, output, 1); return 1;
}
static cmsHPROFILE make_cmyk_proof_fixture(void) {
    cmsHPROFILE rgb = cmsCreate_sRGBProfile(), lab = cmsCreateLab4Profile(NULL), profile = NULL;
    ProofFixtureSamplers samplers = {0}; cmsPipeline *pipeline = NULL; cmsStage *stage = NULL;
    if (!rgb || !lab) goto done;
    samplers.rgb_to_lab = cmsCreateTransform(rgb, TYPE_RGB_DBL, lab, TYPE_Lab_16, INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_NOOPTIMIZE);
    samplers.lab_to_rgb = cmsCreateTransform(lab, TYPE_Lab_16, rgb, TYPE_RGB_DBL, INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_NOOPTIMIZE);
    if (!samplers.rgb_to_lab || !samplers.lab_to_rgb) goto done;
    profile = cmsCreateProfilePlaceholder(NULL); if (!profile) goto done;
    cmsSetProfileVersion(profile, 4.3); cmsSetDeviceClass(profile, cmsSigOutputClass);
    cmsSetColorSpace(profile, cmsSigCmykData); cmsSetPCS(profile, cmsSigLabData);
    if (!cmsWriteTag(profile, cmsSigMediaWhitePointTag, cmsD50_XYZ())) goto failure;
    for (int direction = 0; direction < 2; direction++) {
        int inputs = direction ? 4 : 3, outputs = direction ? 3 : 4;
        pipeline = cmsPipelineAlloc(NULL, inputs, outputs); if (!pipeline) goto failure;
        stage = cmsStageAllocToneCurves(NULL, inputs, NULL); if (!stage || !cmsPipelineInsertStage(pipeline, cmsAT_END, stage)) goto failure; stage = NULL;
        stage = cmsStageAllocCLut16bit(NULL, 17, inputs, outputs, NULL); if (!stage) goto failure;
        if (!cmsStageSampleCLut16bit(stage, direction ? proof_fixture_reverse : proof_fixture_forward, &samplers, 0)) goto failure;
        if (!cmsPipelineInsertStage(pipeline, cmsAT_END, stage)) goto failure; stage = NULL;
        stage = cmsStageAllocToneCurves(NULL, outputs, NULL); if (!stage || !cmsPipelineInsertStage(pipeline, cmsAT_END, stage)) goto failure; stage = NULL;
        if (!cmsWriteTag(profile, direction ? cmsSigAToB0Tag : cmsSigBToA0Tag, pipeline)) goto failure;
        cmsPipelineFree(pipeline); pipeline = NULL;
    }
    if (!cmsLinkTag(profile, cmsSigAToB1Tag, cmsSigAToB0Tag) || !cmsLinkTag(profile, cmsSigAToB2Tag, cmsSigAToB0Tag) ||
        !cmsLinkTag(profile, cmsSigBToA1Tag, cmsSigBToA0Tag) || !cmsLinkTag(profile, cmsSigBToA2Tag, cmsSigBToA0Tag)) goto failure;
    goto done;
failure:
    cmsCloseProfile(profile); profile = NULL;
done:
    if (stage) cmsStageFree(stage); if (pipeline) cmsPipelineFree(pipeline);
    if (samplers.rgb_to_lab) cmsDeleteTransform(samplers.rgb_to_lab); if (samplers.lab_to_rgb) cmsDeleteTransform(samplers.lab_to_rgb);
    if (rgb) cmsCloseProfile(rgb); if (lab) cmsCloseProfile(lab);
    return profile;
}
