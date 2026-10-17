#!/usr/bin/env python3
"""Attach our C ABI to a previously patched, pinned upstream Siril checkout."""
from pathlib import Path
import shutil
import re

root = Path.cwd()
source = root / "siril-src"
# Manual star registration receives its selections and layer from the native
# caller. Keep the original PSF fitter and rigid-transform implementation.
three_stars = source / "src/registration/3stars.c"
text = three_stars.read_text()
text = text.replace('sequence_find_refimage(&com.seq)', 'sequence_find_refimage(args->seq)')
text = text.replace('com.seq.number', 'regargs->seq->number')
# The finalize hook has generic arguments, not registration arguments.
start = text.index('static int _3stars_seqpsf_finalize_hook(')
end = text.index('static void _3stars_free_results()', start)
body = text[start:end].replace('regargs->seq->number', 'args->seq->number')
transfer_start = body.index('\tGSList *iterator;')
transfer_end = body.index('\n\tint refimage', transfer_start)
transfer = body[transfer_start:transfer_end]
body = body[:transfer_start] + body[transfer_end:]
insert = body.index('\n\tif (args->retval)')
body = body[:insert] + '\n' + transfer + body[insert:]
gui_start = body.index('\tg_rw_lock_writer_lock(&com.stars_lock);')
gui_end = body.index('\npsf_end:', gui_start)
body = body[:gui_start] + body[gui_end:]
body = body.replace('g_slist_free(spsfargs->list);', 'g_slist_free_full(spsfargs->list, free);')
text = text[:start] + body + text[end:]
text = text.replace('free(results[i].stars[s]);', 'free_psf(results[i].stars[s]);')
text = text.replace('(regargs->follow_star) ? FOLLOW_STAR_FRAME : REGISTERED_FRAME', '(regargs->follow_star) ? FOLLOW_STAR_FRAME : ORIGINAL_FRAME')
text = text.replace('\t\tfor (int i = 0 ; i < args->seq->number; i++)\n\t\t\tresults[i].stars[awaiting_star - 1] = NULL;\n', '')
text = text.replace('get_registration_layer(&com.seq) : gui_iface.get_reg_layer()', 'regargs->layer : regargs->layer')
needle = '\t\tmemcpy(&com.selection, &_3boxes[awaiting_star - 1], sizeof(rectangle));'
assert text.count(needle) == 1
text = text.replace(needle, '\t\tmemcpy(&com.selection, &_3boxes[i], sizeof(rectangle));')
# Transform matrices are computed against refimage below. Preserve that same
# reference in the saved sequence instead of selecting another frame by FWHM.
needle = 'regargs->seq->reference_image = best_index;'
assert text.count(needle) == 1
text = text.replace(needle, 'regargs->seq->reference_image = refimage;\n\tbest_index = refimage;')
needle = '\t\t\t\t\tstarsin = &(arrayref[k]);'
start = text.index(needle)
end = text.index('\n\t\t\t\tdouble err = cvCalculRigidTransform', start)
body = text[start:end]
assign_end = body.index('\n\t\t\t\t\tif (results[i].stars[j]')
assign = body[:assign_end]
body = body[assign_end:]
insert = body.index('\n', body.index('!= NULL) {'))
body = body[:insert] + '\n' + assign + body[insert:]
text = text[:start] + body + text[end:]
needle = '\t\tcurrent_regdata[i].roundness = sumy / sumx;'
assert text.count(needle) == 1
text = text.replace(needle, '\t\tcurrent_regdata[i].quality = 0;\n' + needle)
text += '''
void siril_ipados_reset_three_stars(void) {
    _3stars_free_results();
    awaiting_star = 0;
    selected_stars = 0;
}
'''
three_stars.write_text(text)
# Comet output owns a new regdata array, not the input's PSF allocations.
# Keep inherited scalar measurements; a newly created shift has no quality
# measurement (negative is explicitly absent in the mobile quality graph).
comet = source / "src/registration/comet.c"
text = comet.read_text()
needle = 'regargs->imgparam = malloc(args->seq->number * sizeof(imgdata));'
assert text.count(needle) == 1
text = text.replace(needle, 'regargs->imgparam = calloc(args->seq->number, sizeof(imgdata));')
needle = '\t\tregargs->imgparam[i].incl = !SEQUENCE_DEFAULT_INCLUDE; // this will be set by the image hook'
assert text.count(needle) == 1
text = text.replace(needle, '\t{\n' + needle + '\n\t\tif (regargs->imgparam[i].date_obs)\n'
    '\t\t\tregargs->imgparam[i].date_obs = g_date_time_ref(regargs->imgparam[i].date_obs);\n\t}')
needle = '\t\tcadata->current_regdata = NULL;\n\t}\n'
assert text.count(needle) == 1
text = text.replace(needle, needle + '\tfor (int i = 0; i < args->seq->number; i++) {\n'
    '\t\tregargs->regparam[i].fwhm_data = NULL;\n'
    '\t\tif (!cadata->current_regdata || guess_transform_from_H(cadata->current_regdata[i].H) == NULL_TRANSFORMATION)\n'
    '\t\t\tregargs->regparam[i].quality = -1.0;\n\t}\n')
needle = '\tfree_sequence(&seq, FALSE);'
assert text.count(needle) == 1
text = text.replace(needle, needle + '\n\tfree(distoparam);')
comet.write_text(text)
# A singleton third FITS axis is a monochrome image. Normalize the working
# layout before the full/partial readers' three-channel checks.
fits_io = source / "src/io/image_format_fits.c"
text = fits_io.read_text()
needle = '\tif (fit->naxis == 3 && fit->naxes[2] != 3) {'
assert text.count(needle) == 3
text = text.replace(needle, '\tif (fit->naxis == 3 && fit->naxes[2] == 1) fit->naxis = 2;\n' + needle)
needle = '\tfit->naxes[2] = nblayer;\n\tfit->naxis = 3;'
assert text.count(needle) == 1
text = text.replace(needle, '\tfit->naxes[2] = nblayer;\n\tfit->naxis = nblayer == 1 ? 2 : 3;')
fits_io.write_text(text)
# Synchronous single-star registration transfers PSFs to regdata and never
# runs the GUI idle. Release only its list containers and argument wrapper.
sequence_io = source / "src/io/sequence.c"
text = sequence_io.read_text()
# Metadata-only SER reads need the indexed trailer date, just like the full
# and partial readers. Comet's reference-date path uses this generic reader.
start = text.index("int seq_read_frame_metadata(")
start = text.index("\t\tcase SEQ_SER:", start)
end = text.index("\t\tcase SEQ_FITSEQ:", start)
body = text[start:end]
assert body.count("\t\t\tbreak;") == 1
body = body.replace("\t\t\tbreak;", "\t\t\tdest->keywords.date_obs = ser_read_frame_date(seq->ser_file, index);\n\t\t\tbreak;")
text = text[:start] + body + text[end:]
# A perfectly constant selection can produce a spurious converged Gaussian.
# Reject zero contrast before fitting; preserve the original fitter otherwise.
needle = '\tdata->psf = psf_get_minimisation(fit, 0, &psfarea, spsfargs->for_photometry, spsfargs->init_from_center, ps, TRUE, com.pref.starfinder_conf.profile, &error);'
assert text.count(needle) == 1
text = text.replace(needle, '\tgboolean has_contrast = TRUE;\n'
    '\tif (!spsfargs->for_photometry) {\n'
    '\t\timstats *contrast = statistics(NULL, -1, fit, 0, NULL, STATS_MINMAX, SINGLE_THREADED);\n'
    '\t\thas_contrast = contrast && isfinite(contrast->min) && isfinite(contrast->max) && contrast->max > contrast->min;\n'
    '\t\tif (contrast) free_stats(contrast);\n\t}\n'
    '\tif (!has_contrast) error = PSF_ERR_INVALID_IMAGE;\n'
    '\tif (has_contrast)\n' + needle)
start = text.index('int seqpsf_finalize_hook(')
end = text.index('gboolean end_seqpsf(', start)
body = text[start:end]
needle = '\tif (args->retval)\n\t\treturn 0;'
assert body.count(needle) == 1
body = body.replace(needle, '\tif (args->retval) {\n'
    '\t\tif (args->already_in_a_thread && !spsfargs->for_photometry) {\n'
    '\t\t\tfor (GSList *it = spsfargs->list; it; it = it->next) {\n'
    '\t\t\t\tstruct seqpsf_data *data = it->data;\n'
    '\t\t\t\tif (data->psf) free_psf(data->psf);\n'
    '\t\t\t}\n\t\t\tg_slist_free_full(spsfargs->list, free);\n'
    '\t\t\tfree(spsfargs); args->user = NULL;\n'
    '\t\t}\n\t\treturn 0;\n\t}')
text = text[:start] + body + text[end:]
needle = '\t\t\twrite_regdata(seq, args->layer_for_partial, spsfargs->list, FALSE);\n\t\t}\n\t\treturn 0;'
assert text.count(needle) == 1
text = text.replace(needle, '\t\t\twrite_regdata(seq, args->layer_for_partial, spsfargs->list, FALSE);\n\t\t}\n'
    '\t\tif (args->already_in_a_thread) {\n'
    '\t\t\tg_slist_free_full(spsfargs->list, free);\n'
    '\t\t\tfree(spsfargs); args->user = NULL;\n'
    '\t\t}\n\t\treturn 0;')
sequence_io.write_text(text)
# Crop Drizzle weights with the same original geometry operation as pixels.
# The native caller validates every output weight before enabling Drizzle.
geometry = source / "src/algos/geometry.c"
text = geometry.read_text()
needle = '#include "io/image_format_fits.h"'
assert text.count(needle) == 1
text = text.replace(needle, '#include "io/fits_keywords.h"\n' + needle)
start = text.index('int crop_image_hook(struct generic_seq_args *args,')
end = text.index('int crop_finalize_hook(', start)
body = text[start:end]
needle = '\tint ret = crop(fit, &(c_args->area));'
assert body.count(needle) == 1
body = body.replace(needle, '\trectangle area = c_args->area;\n\tint ret = crop(fit, &area);' + r'''
    if (!ret && args->seq->is_drizzle) {
        fits weights = {0};
        gchar *input = get_sequence_cache_filename(args->seq, i, "drizztmp", "fit", NULL);
        gchar *output = get_sequence_cache_filename(args->seq, i, "drizztmp", "fit", args->new_seq_prefix);
        ret = !input || !output || readfits(input, &weights, NULL, FALSE);
        if (!ret && (weights.rx != args->seq->rx || weights.ry != args->seq->ry ||
                weights.naxes[2] != args->seq->nb_layers)) ret = 1;
        // Count maps describe the output grid, never a raw Bayer mosaic.
        // Upstream applyreg can leave the input CFA metadata on these maps.
        if (!ret) {
            clear_Bayer_information(&weights);
            rectangle weight_area = area;
            ret = crop(&weights, &weight_area);
        }
        if (!ret) ret = savefits(output, &weights);
        clearfits(&weights);
        g_free(input); g_free(output);
    }
''')
geometry.write_text(text[:start] + body + text[end:])
# generic_image_worker passes args->user to every log hook.
rgradient = source / "src/filters/rgradient.c"
text = rgradient.read_text()
needle = '''\tstruct generic_img_args *ga = (struct generic_img_args *) p;
\tstruct rgradient_data *args = (struct rgradient_data *) ga->user;'''
assert text.count(needle) == 1
rgradient.write_text(text.replace(needle, '\tstruct rgradient_data *args = (struct rgradient_data *) p;'))
# A registration result is usable only if the original sequence writer succeeds.
registration = source / "src/registration/registration.c"
text = registration.read_text()
needle = '\tif (!args->retval)\n\t\twriteseqfile(args->seq);'
assert text.count(needle) == 1
registration.write_text(text.replace(needle, '\tif (!args->retval)\n\t\targs->retval = writeseqfile(args->seq);'))
# Keep the original sequence keyword hooks and surface failed updates/writes.
# The typed bridge bypasses shell quoting and stops on the first failed frame.
keywords = source / "src/io/fits_keywords.c"
text = keywords.read_text()
needle = '\t\t\tsavefits(root, fit);'
assert text.count(needle) == 1
text = text.replace(needle, '\t\t\tretval = savefits(root, fit);')
start = text.index('static int keywords_image_hook(')
end = text.index('static int keywords_finalize_hook(', start)
body = text[start:end]
assert body.count('\treturn 0;') == 1
needle = 'fit_sequence_get_image_filename(arg->seq, i, root, FALSE)'
assert body.count(needle) == 1
body = body.replace(needle, 'fit_sequence_get_image_filename_checkext(arg->seq, i, root)')
needle = '\t\tsave_fits_header(fit);'
assert body.count(needle) == 1
body = body.replace(needle, '''\t\tif (!retval) retval = save_fits_keywords(fit);
\t\tif (!retval) retval = save_wcs_keywords(fit);
\t\tif (!retval) retval = save_history_keywords(fit);
\t\tif (!retval) retval = save_fits_unknown_keywords(fit);
\t\tif (!retval) fits_flush_file(fit->fptr, &retval);''')
text = text[:start] + body.replace('\treturn 0;', '\treturn retval;') + text[end:]
needle = '\tif (!arg->retval)\n\t\twriteseqfile(arg->seq);'
assert text.count(needle) == 1
text = text.replace(needle, '\tif (!arg->retval)\n\t\tretval = writeseqfile(arg->seq);')
text += r'''

#include "core/processing_thread.h"
int siril_ipados_sequence_keywords(sequence *seq, struct keywords_data *data) {
    struct generic_seq_args *args = create_default_seqargs(seq);
    args->filtering_criterion = seq_filter_included;
    args->nb_filtered_images = seq->selnum;
    args->stop_on_error = TRUE;
    args->parallel = FALSE;
    args->prepare_hook = keywords_prepare_hook;
    args->image_hook = keywords_image_hook;
    args->finalize_hook = keywords_finalize_hook;
    args->idle_function = end_keywords_sequence;
    args->has_output = FALSE;
    args->output_type = get_data_type(seq->bitpix);
    args->description = "keywords update";
    args->user = data;
    waiting_for_thread();
    if (!start_in_new_thread(generic_sequence_worker, args)) {
        free(data->FITS_key); free(data->newkey);
        free(data->value); free(data->comment); free(data);
        free_generic_seq_args(args, TRUE);
        return 0;
    }
    return GPOINTER_TO_INT(waiting_for_thread()) == 0;
}
'''
keywords.write_text(text)
# CFITSIO can offer reader handles even when Siril has no OpenMP. The
# upstream metadata reader rejected this valid single-thread configuration.
sequence_io = source / "src/io/sequence.c"
text = sequence_io.read_text()
start = text.index('int seq_read_frame_metadata(')
end = text.index('int seq_read_frame_date(', start)
body = text[start:end]
needle = '''#ifdef _OPENMP
\t\t\t\tint thread_id = omp_get_thread_num();'''
assert body.count(needle) == 1
body = body.replace(needle, '''\t\t\t\tint thread_id = 0;
#ifdef _OPENMP
\t\t\t\tthread_id = omp_get_thread_num();
#endif''')
needle = '''#else
\t\t\t\treturn 1;
#endif'''
assert body.count(needle) == 1
body = body.replace(needle, '')
sequence_io.write_text(text[:start] + body + text[end:])
directories = source / "src/core/siril_app_dirs.c"
text = directories.read_text()
needle = 'static void search_for_spcc_repo_dir() {\n'
assert text.count(needle) == 1
text = text.replace(needle, needle + '''#ifdef OS_IOS
    const gchar *bundled = g_getenv("SIRIL_SPCC_DIR");
    if (bundled && g_file_test(bundled, G_FILE_TEST_IS_DIR)) {
        siril_spcc_repo_dir = g_strdup(bundled);
        return;
    }
#endif
''')
directories.write_text(text)
commands = source / "src/core/command.c"
text = commands.read_text()
needle = 'if (oscsensor || mono_or_osc == 1) {'
assert text.count(needle) == 1
# Explicit sensor options must win over the desktop's saved camera mode.
text = text.replace(needle, 'if (oscsensor || (!monosensor && mono_or_osc == 1)) {')
commands.write_text(text)
icc = source / "src/core/icc_profile.c"
text = icc.read_text()
start = text.index('int icc_convert_to_hook(')
end = text.index('gchar *icc_convert_to_log_hook(', start)
body = text[start:end]
# The original transform reads export_intent, while this hook previously changed
# processing_intent: command intent options silently had no effect.
assert body.count('com.pref.icc.processing_intent') == 3
body = body.replace('com.pref.icc.processing_intent', 'com.pref.icc.export_intent')
needle = '\tsiril_colorspace_transform(fit, args->profile);'
assert body.count(needle) == 1
body = body.replace(needle, '\tGSList *previous_tail = g_slist_last(fit->history);\n' + needle)
# Failed transforms leave the old profile attached. Its presence alone cannot
# establish success; every completed original transform appends FITS history.
body = body.replace('if (!fit->icc_profile) {', 'if (!fit->icc_profile || g_slist_last(fit->history) == previous_tail) {')
icc.write_text(text[:start] + body + text[end:])
text = icc.read_text()
start = text.index('void siril_colorspace_transform(fits *fit, cmsHPROFILE profile) {')
end = text.index('void icc_auto_assign_or_convert(', start)
body = text[start:end]
needle = '\tcmsHTRANSFORM transform = cmsCreateTransformTHR((threaded ? com.icc.context_threaded : com.icc.context_single), fit->icc_profile, srctype, profile, desttype, com.pref.icc.export_intent, com.icc.rendering_flags);'
assert body.count(needle) == 1
# The bundled fast-float CLUT approximation loses ~5.6e-4 for absolute
# colorimetry with a different media white. Preserve floating-point precision
# using the unoptimized public LCMS pipeline for that actual failing case.
body = body.replace(needle, '''\tgboolean precise_absolute = fit->type == DATA_FLOAT && com.pref.icc.export_intent == INTENT_ABSOLUTE_COLORIMETRIC;
\tcmsContext context = precise_absolute ? NULL : (threaded ? com.icc.context_threaded : com.icc.context_single);
\tcmsUInt32Number flags = com.icc.rendering_flags | (precise_absolute ? cmsFLAGS_NOOPTIMIZE : 0);
\tcmsHTRANSFORM transform = cmsCreateTransformTHR(context, fit->icc_profile, srctype, profile, desttype, com.pref.icc.export_intent, flags);''')
icc.write_text(text[:start] + body + text[end:])
masks = source / "src/core/masks.c"
text = masks.read_text()
# These original allocators used the bit count as a byte count (8x excess).
# Saved display masks use the same original allocator as processing masks.
needle = 'malloc(fit->rx * fit->ry * bitpix)'
assert text.count(needle) == 3
text = text.replace(needle, 'malloc((size_t)fit->rx * fit->ry * (bitpix / 8))')
assert text.count('calloc(fit->rx * fit->ry, bitpix)') == 1
text = text.replace('calloc(fit->rx * fit->ry, bitpix)', 'calloc((size_t)fit->rx * fit->ry, bitpix / 8)')
assert text.count('calloc(npixels, bitpix)') == 1
masks.write_text(text.replace('calloc(npixels, bitpix)', 'calloc(npixels, bitpix / 8)'))
formats = source / "src/io/image_formats_libraries.c"
text = formats.read_text()
start = text.index('static int readraw_in_cfa(')
end = text.index('int open_raw_files(', start)
body = text[start:end]
needle = '\tlibraw_data_t *raw = libraw_init(0);'
assert body.count(needle) == 1
body = body.replace(needle, needle + '\n\tif (!raw) return OPEN_IMAGE_ERROR;')
# The decoder's early open/unpack/no-CFA failures must release its handle.
needle = '\t\tsiril_log_error("Error in libraw %s\\n", libraw_strerror(ret));\n\t\treturn OPEN_IMAGE_ERROR;'
assert body.count(needle) == 2
body = body.replace(needle, '\t\tsiril_log_error("Error in libraw %s\\n", libraw_strerror(ret));\n\t\tlibraw_close(raw);\n\t\treturn OPEN_IMAGE_ERROR;')
needle = '\t\t\t\t"no RAW data available.\\n"));\n\t\treturn OPEN_IMAGE_ERROR;'
assert body.count(needle) == 1
body = body.replace(needle, '\t\t\t\t"no RAW data available.\\n"));\n\t\tlibraw_close(raw);\n\t\treturn OPEN_IMAGE_ERROR;')
formats.write_text(text[:start] + body + text[end:])

# HEIF planes have a byte stride that can exceed the packed row length.
# Honor it for every row, including 10/12/16-bit data and optional alpha.
text = formats.read_text()
# The iOS decoder budget uses the original platform memory helper.
needle = '#include "core/proto.h"'
assert text.count(needle) == 1
text = text.replace(needle, needle + '\n#include "core/OS_utils.h"')
start = text.index('int readheif(')
end = text.index('\n#endif', text.index('return OPEN_IMAGE_OK;', start))
body = text[start:end]
a = body.index('\tgboolean threaded = !processing_in_worker_thread();', body.index('heif_decode_image'))
b = body.index('\n\tif (mono) {', a)
body = body[:a] + '''
    const unsigned int mask = bit_depth == 16 ? 65535u : (1u << bit_depth) - 1;
    for (int y = 0; y < height; y++) {
        const uint8_t *row = udata + (size_t)y * stride;
        for (int x = 0; x < width; x++) {
            WORD values[3];
            for (int c = 0; c < 3; c++) {
                size_t sample = (size_t)x * nchannels + c;
                if (bit_depth > 8) {
                    uint16_t value; memcpy(&value, row + sample * sizeof value, sizeof value);
                    values[c] = roundf_to_WORD((value & mask) * (65535.f / mask));
                } else values[c] = row[sample];
                data[(size_t)c * npixels + (size_t)y * width + x] = values[c];
            }
            if (values[0] != values[1] || values[0] != values[2]) mono = FALSE;
        }
    }
''' + body[b:]
needle = '\tint has_alpha = heif_image_handle_has_alpha_channel(handle);'
assert body.count(needle) == 1
body = body.replace(needle, '''#ifdef OS_IOS
    int image_width = heif_image_handle_get_width(handle), image_height = heif_image_handle_get_height(handle);
    if (image_width <= 0 || image_height <= 0 || image_width > 100000 || image_height > 100000 ||
        (double)image_width * image_height * 16 > (double)get_available_memory() * .8) {
        free(icc_buffer); heif_image_handle_release(handle); heif_context_free(ctx); heif_deinit();
        return OPEN_IMAGE_ERROR;
    }
#endif
''' + needle)
body = body.replace('if (bit_depth < 0) {', 'if (bit_depth <= 0 || bit_depth > 16) {')
formats.write_text(text[:start] + body + text[end:])

conversion = source / "src/io/conversion.c"
text = conversion.read_text()
needle = '!g_ascii_strcasecmp(extension, "heif")))'
assert text.count(needle) == 1
conversion.write_text(text.replace(needle, '!g_ascii_strcasecmp(extension, "heif") || !g_ascii_strcasecmp(extension, "hif")))'))

# Original JPEG XL readers return a channel count, so failures must be negative.
# Release the compressed input and propagate encoder / filesystem failures.
text = formats.read_text()
start = text.index('int readjxl(')
end = text.index('int savejxl(', start)
body = text[start:end]
needle = '\t\tsiril_log_debug("Error while decoding the jxl file\\n");\n\t\treturn 1;'
assert body.count(needle) == 1
body = body.replace(needle, '\t\tsiril_log_debug("Error while decoding the jxl file\\n");\n'
                    '\t\tg_free(jxl_data); free(pixels); free(icc_profile); free(internal_icc_profile);\n\t\treturn -1;')
body = body.replace('\tclearfits(fit);', '\tg_free(jxl_data);\n\tclearfits(fit);', 1)
text = text[:start] + body + text[end:]
start = text.index('int savejxl(')
body = text[start:]
needle = '\tEncodeJpegXlOneshotWrapper(buffer, fit->rx,'
assert body.count(needle) == 1
body = body.replace(needle, '\tint encode_error = EncodeJpegXlOneshotWrapper(buffer, fit->rx,', 1)
needle = '\tg_file_set_contents(name, (const gchar *) compressed, compressed_length, &error);'
assert body.count(needle) == 1
body = body.replace(needle, '\tgboolean saved = !encode_error && g_file_set_contents(name, (const gchar *) compressed, compressed_length, &error);')
needle = '\t\tsiril_log_error(_("Error interleaving image\\n"));\n\t}'
assert body.count(needle) == 1
body = body.replace(needle, '\t\tsiril_log_error(_("Error interleaving image\\n"));\n\t\tfree(buffer); free(filename); return OPEN_IMAGE_ERROR;\n\t}')
needle = '\tfree(filename);\n\tg_error_free(error);\n\treturn OPEN_IMAGE_OK;'
assert body.count(needle) == 1
body = body.replace(needle, '\tfree(filename); free(profile);\n\tif (error) g_error_free(error);\n\treturn saved ? OPEN_IMAGE_OK : OPEN_IMAGE_ERROR;')
needle = '\tsiril_log_info(_("Save complete.\\n"));'
assert body.count(needle) == 1
body = body.replace(needle, '', 1)
body = body.replace('\tfree(buffer);\n\tfree(compressed);', '\tif (saved) siril_log_info(_("Save complete.\\n"));\n\tfree(buffer);\n\tfree(compressed);', 1)
formats.write_text(text[:start] + body)

wrapper = source / "src/io/SirilJpegXLWrapper.cpp"
text = wrapper.read_text()
needle = '#include <vector>'
assert text.count(needle) == 1
text = text.replace(needle, needle + '\n#include "core/OS_utils.h"')
needle = '      *xsize = info.xsize;'
assert text.count(needle) == 1
text = text.replace(needle, '''#ifdef OS_IOS
      if (!info.xsize || !info.ysize || info.xsize > 100000 || info.ysize > 100000 ||
          (info.num_color_channels != 1 && info.num_color_channels != 3) || info.num_extra_channels != 0 ||
          (double)info.xsize * info.ysize * info.num_color_channels * 12 > (double)get_available_memory() * .8) {
        fprintf(stderr, "JPEG XL layout unsupported or exceeds the available memory budget\\n");
        return false;
      }
#endif
''' + needle)
wrapper.write_text(text)

wrapper = source / "src/io/SirilXISFReader.cpp"
text = wrapper.read_text()
needle = 'catch (const LibXISF::Error &error)'
assert text.count(needle) == 2
# Numeric XML parsing and allocation may throw standard exceptions as well.
wrapper.write_text(text.replace(needle, 'catch (const std::exception &error)'))

text = commands.read_text()
start = text.index('int process_savejxl(')
end = text.index('int process_savepng(', start)
body = text[start:end]
needle = 'double quality = g_ascii_strtod(arg, &end);'
assert body.count(needle) == 1
body = body.replace(needle, 'quality = g_ascii_strtod(arg, &end);')
commands.write_text(text[:start] + body + text[end:])

# PCC's automatic background must use the worker's image, not the desktop's
# global displayed image. The two can have different geometry in embedding.
path = source / "src/algos/statistics_float.c"
text = path.read_text()
start = text.index('double robust_median_f(')
body = text[start:]
needle = '\t\tx1 = gfit->rx;\n\t\ty1 = gfit->ry;'
assert body.count(needle) == 1
body = body.replace(needle, '\t\tx1 = fit->rx;\n\t\ty1 = fit->ry;', 1)
path.write_text(text[:start] + body)
destination = source / "src/ipados"
destination.mkdir(exist_ok=True)
for name in ("SirilCore.c", "SirilCore.h", "SirilAdvanced.inc", "SirilDeconvolution.inc", "SirilAstrometry.inc", "SirilSER.inc", "SirilDisplay.inc", "core-link-probe.c", "core-runtime-tests.c", "xisf-runtime-tests.inc", "photometry-runtime-tests.inc", "ser-runtime-tests.inc", "jxl-runtime-tests.inc", "cfa-format-tests.inc", "heif-runtime-tests.inc", "keyword-runtime-tests.inc", "display-runtime-tests.inc", "icc-runtime-tests.inc", "display-icc-tests.inc", "display-overlay-tests.inc", "display-proof-tests.inc", "cmyk-proof-fixture.inc", "noise-runtime-tests.inc", "large-image-runtime-tests.inc", "SirilPatternRegistration.inc", "SirilCometRegistration.inc", "SirilMultipoint.inc"):
    shutil.copy2(root / "native" / name, destination / name)
# Reuse the pinned desktop LUT arithmetic without GTK state or its UI cache.
# The iPad bridge owns the image, level bounds, destination and STF parameters.
text = (source / "src/gui-gtk4/image_display.c").read_text()
a = text.index('static int make_index_for_current_display(int vport, float *fidx) {')
b = text.index('static int make_index_for_rainbow(', a)
lut = text[a:b]
a = lut.index('\tfloat slope, delta')
lut = 'static int embedded_original_display_lut(int mode, WORD lo, WORD hi, BYTE *index, struct mtf_params params, float *fidx) {\n' + lut[a:]
lut = lut.replace('\tBYTE *index;\n', '')
a = lut.index('\tif(!(slope == last_pente')
b = lut.index('\t/************* Building the remap_index', a)
lut = lut[:a] + lut[b:]
a = lut.index('\tint target_index = ')
b = lut.index('\n\tfor (i = 0;', a)
lut = lut[:a] + lut[b:]
lut = lut.replace('gui.rendering_mode', 'mode').replace('gfit->orig_bitpix', 'FLOAT_IMG').replace('stf[target_index]', 'params')
lut = lut.replace('gui.remap_index', 'display index') # comments and debug text
lut = lut.replace(', vport);', ', 0);')
lut = lut.replace('\tlast_pente = slope;\n\tlast_mode = mode;\n', '')
lut = lut.replace('INDEX_UNSUPPORTED', '1').replace('INDEX_BUILT', '0')
assert 'gui.' not in lut and 'gfit' not in lut and 'last_' not in lut
(destination / "SirilDisplayLUT.inc").write_text('// SPDX-License-Identifier: GPL-3.0-or-later\n// Extracted from the pinned original GTK display LUT; no pixel mutation.\n' + lut)
rainbow_start = text.index('static int make_index_for_rainbow(BYTE index[][3]) {')
rainbow_end = text.index('\n/*****************************************************************************', rainbow_start)
(destination / "SirilDisplayRainbow.inc").write_text('// SPDX-License-Identifier: GPL-3.0-or-later\n// Original Siril single-channel rainbow palette.\n' + text[rainbow_start:rainbow_end])
icc_text = (source / "src/core/icc_profile.c").read_text()
start = icc_text.index('static gboolean siril_color_profile_get_rgb_matrix_colorants_d50 (')
end = icc_text.index('static void siril_color_profile_set_tag (', start)
(destination / "SirilICCPrimaries.inc").write_text('// SPDX-License-Identifier: GPL-3.0-or-later\n// Original D50 profile colorant extraction used by the Siril chromaticity plot.\n' + icc_text[start:end])
proof_start = icc_text.index('static cmsHTRANSFORM build_proofing_transform(gboolean float_input) {')
proof_end = icc_text.index('cmsHTRANSFORM initialize_proofing_transform()', proof_start)
gamut_start = icc_text.index('static cmsHTRANSFORM build_gamut_transform()')
gamut_end = icc_text.index('/* Cached accessor for the above.', gamut_start)
display_icc = icc_text[proof_start:proof_end] + icc_text[gamut_start:gamut_end]
display_icc = display_icc.replace('build_proofing_transform(gboolean float_input)', 'embedded_original_proofing_transform(fits *fit, cmsHPROFILE monitor, gboolean float_input, cmsHPROFILE proof, const SirilDisplayOptions *options)')
display_icc = display_icc.replace('build_gamut_transform()', 'embedded_original_gamut_transform(fits *fit, cmsHPROFILE monitor, cmsHPROFILE proof, const SirilDisplayOptions *options)')
display_icc = re.sub(r'\(com\.gui_icc\.soft_proof && com\.pref\.icc\.soft_proofing_profile_active\)\s*\?\s*com\.gui_icc\.soft_proof\s*:\s*com\.gui_icc\.monitor', '(proof ? proof : monitor)', display_icc)
display_icc = display_icc.replace('com.gui_icc.monitor', 'monitor').replace('gfit', 'fit')
display_icc = display_icc.replace('com.gui_icc.proofing_flags', '(cmsFLAGS_SOFTPROOFING | ((options->black_point && options->rendering_intent != INTENT_ABSOLUTE_COLORIMETRIC) ? cmsFLAGS_BLACKPOINTCOMPENSATION : 0))')
display_icc = display_icc.replace('com.gui_icc.gamut_check', '(options->gamut_check && proof)')
display_icc = display_icc.replace('com.pref.icc.rendering_intent', 'options->rendering_intent').replace('com.pref.icc.proofing_intent', 'options->proofing_intent')
for mutex in ('soft_proof_profile_mutex', 'monitor_profile_mutex'):
    for action in ('lock', 'unlock'):
        display_icc = display_icc.replace(f'\tg_mutex_{action}(&{mutex});\n', '')
assert 'com.gui_icc' not in display_icc and 'gfit' not in display_icc
same_start = icc_text.index('gboolean same_primaries(cmsHPROFILE a, cmsHPROFILE b, cmsHPROFILE c) {')
same_end = icc_text.index('void reset_icc_transforms()', same_start)
same = icc_text[same_start:same_end].replace('gboolean same_primaries(cmsHPROFILE a, cmsHPROFILE b, cmsHPROFILE c)', 'static gboolean embedded_original_same_primaries(cmsHPROFILE a, cmsHPROFILE b, cmsHPROFILE c, int proofing_intent)')
same = same.replace('com.pref.icc.proofing_intent', 'proofing_intent')
display_icc = same + display_icc
(destination / "SirilDisplayICC.inc").write_text('// SPDX-License-Identifier: GPL-3.0-or-later\n// Original display transforms adapted to an owned image and explicit sRGB target.\n// Called under the bridge engine mutex; soft-proof/gamut-warning UI is separate.\n' + display_icc)
meson = source / "src/meson.build"
text = meson.read_text()
needle = "siril_lib = static_library('siril',"
assert text.count(needle) == 1, "Pinned upstream static library layout changed"
text = text.replace(needle, "if enable_embedded\n  src_files += files('ipados/SirilCore.c')\nendif\n\n" + needle)
text += """

# Resolve every compiled core symbol against iPadOS and the headless stubs.
# This binary is only link-checked; executing it requires an Apple device.
if enable_embedded
  executable('siril-ipados-link-probe', 'ipados/core-link-probe.c',
    dependencies: siril_dep,
    link_whole: siril_lib,
    link_args: siril_link_arg,
    c_args: siril_c_flag,
    cpp_args: siril_cpp_flag)
  executable('siril-ipados-runtime-tests', 'ipados/core-runtime-tests.c',
    dependencies: siril_dep,
    c_args: siril_c_flag,
    cpp_args: siril_cpp_flag)
endif
"""
meson.write_text(text)

# Read the same configured table used by execute_command, without maintaining
# a separate list that could drift away from upstream features or build flags.
processor = source / "src/core/command_line_processor.c"
processor.write_text(processor.read_text() + r'''

const char *siril_command_catalog(void) {
  static gsize catalog_initialized;
  static char *catalog;
  if (g_once_init_enter(&catalog_initialized)) {
    GString *text = g_string_new(NULL);
    for (size_t i = 0; i < G_N_ELEMENTS(commands); i++) {
      if (!commands[i].scriptable || !strcmp(commands[i].name, "exit") ||
          !strcmp(commands[i].name, "livestack") || !strcmp(commands[i].name, "stop_ls")) continue;
      gchar *usage = g_strdup(commands[i].usage);
      for (char *p = usage; *p; p++) if (*p == '\n' || *p == '\t') *p = ' ';
      g_string_append_printf(text, "%s\t%s\n", commands[i].name, usage);
      g_free(usage);
    }
    catalog = g_string_free(text, FALSE);
    g_once_init_leave(&catalog_initialized, 1);
  }
  return catalog;
}
''')

# iPadOS gives Apps a per-process memory budget, unlike desktop macOS.
utilities = source / "src/core/OS_utils.c"
text = utilities.read_text()
needle = "#ifdef OS_OSX\nstatic gint64 find_space(const gchar *name) {"
assert text.count(needle) == 1
text = text.replace(needle, """#ifdef OS_IOS
static gint64 find_space(const gchar *name) {
    /* iPad sandbox volumes may omit the desktop format-description key.
     * Query the available capacity itself instead of requiring APFS metadata. */
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:name];
        NSURL *url = [NSURL fileURLWithPath:path];
        NSNumber *capacity = nil;
        if ([url getResourceValue:&capacity forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil]
                && capacity && [capacity longLongValue] > 0) return [capacity longLongValue];
        capacity = nil;
        if ([url getResourceValue:&capacity forKey:NSURLVolumeAvailableCapacityKey error:nil] && capacity)
            return [capacity longLongValue];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfFileSystemForPath:path error:nil];
        NSNumber *freeSpace = attributes[NSFileSystemFreeSize];
        return freeSpace ? [freeSpace longLongValue] : -1;
    }
}
#elif defined(OS_OSX)
static gint64 find_space(const gchar *name) {""")
needle = "guint64 get_available_memory() {\n#if defined(__linux__) || defined(__CYGWIN__)"
assert text.count(needle) == 1
text = text.replace(needle, """#ifdef OS_IOS
#include <os/proc.h>
#include <TargetConditionals.h>
#endif
guint64 get_available_memory() {
#if defined(OS_IOS)
    /* This API reports zero in the simulator. Keep a conservative test budget;
     * physical iPads use the real per-process remaining-memory estimate. */
#if TARGET_OS_SIMULATOR
    return (guint64)512 * 1024 * 1024;
#else
    return (guint64)os_proc_available_memory();
#endif
#elif defined(__linux__) || defined(__CYGWIN__)""")
utilities.write_text(text)

# Expose an original per-frame sequence hook for a matching native preview.
# No algorithm is copied or reimplemented; static hooks stay in their own TU.
background = source / "src/algos/background_extraction.c"
background.write_text(background.read_text() + r'''

int siril_ipados_background_sequence_preview(fits *fit, struct background_data *data) {
    sensor_pattern pattern = get_cfa_pattern_index_from_string(fit->keywords.bayer_pattern);
    data->is_cfa = fit->naxes[2] == 1 && pattern >= BAYER_FILTER_MIN && pattern <= BAYER_FILTER_MAX;
    struct generic_seq_args args = { .user = data };
    return data->is_cfa && data->method != BACKGROUND_METHOD_AUTO
        ? bgcfa_image_hook(&args, 0, 0, fit, NULL, 1)
        : background_image_hook(&args, 0, 0, fit, NULL, 1);
}
''')

# Upstream's luminance mask command currently points at the channel parser.
# Bind it to the existing original luminance parser; keep the algorithm intact.
command_table = source / "src/core/command_list.h"
text = command_table.read_text()
old = 'process_mask_from_channel, STR_MASK_FROM_LUM'
assert text.count(old) == 1
command_table.write_text(text.replace(old, 'process_mask_from_lum, STR_MASK_FROM_LUM'))

# PixelMath's original integer branch used variable slot zero for plane bounds
# even for $T-only evaluation. Match the existing float branch's actual bounds.
# Constant rescaling must remain finite; failed expressions must not rescale an
# uninitialized output. Release the previous headless single-image owner.
runner = source / "src/pixelMath/pixel_math_runner.c"
text = runner.read_text()
assert text.count("var_fit[0].naxes[0] * var_fit[0].naxes[1]") == 2
text = text.replace("var_fit[0].naxes[0] * var_fit[0].naxes[1]", "width * height")
assert text.count("if (args->rescale) {") == 1
text = text.replace("if (args->rescale) {", "if (args->rescale && !failed) {")
text = text.replace("/ (float)(maximum - minimum) + args->min",
                    "/ (float)(maximum == minimum ? 1.f : maximum - minimum) + args->min")
text = text.replace("/ (maximum - minimum)) + args->min",
                    "/ (maximum == minimum ? 1.f : maximum - minimum)) + args->min")
needle = "if (com.headless) {\n\t\tif (!failed) {\n\t\t\tclearfits(gfit);"
assert text.count(needle) == 1
text = text.replace(needle, "if (com.headless) {\n\t\tif (!failed) {\n\t\t\tclose_single_image();")
# Whole variable tokens prevent I1 from contributing metadata merely because
# I10 appears. Statistics-only use is still a use of that variable's image.
needle = '\t\tconst gchar *test = g_strrstr(result, image[j]);\n\t\tif (test) {'
assert text.count(needle) == 1
text = text.replace(needle, '\t\tgchar *escaped = g_regex_escape_string(image[j], -1);\n'
    '\t\tgchar *pattern = g_strconcat("\\\\b", escaped, "\\\\b", NULL);\n'
    '\t\tgboolean used = g_regex_match_simple(pattern, result, 0, 0);\n'
    '\t\tg_free(pattern); g_free(escaped);\n\t\tif (used) {')
needle = '\t\t\t\t\tif (g_strcmp0(param, image[j]) == 0) {'
assert text.count(needle) == 1
text = text.replace(needle, needle + '\n\t\t\t\t\t\tvar_fit_mask[j] = TRUE;')
runner.write_text(text)

# The original bilateral history exceeds its fixed 90-byte stack buffer even
# at default parameters. Preserve the full history with an owned string.
command = source / "src/core/command.c"
text = command.read_text()
start = text.index("int process_epf(")
end = text.index("int process_getref(", start)
epf = text[start:end]
assert epf.count("char log[90];") == 1
epf = epf.replace("char log[90];", "gchar *log = NULL;")
epf = epf.replace("sprintf(log,", "log = g_strdup_printf(")
epf = epf.replace("g_slist_append(gfit->history, g_strdup(log))", "g_slist_append(gfit->history, log)")
# The original GUI permits zero modulation (identity); the native command
# parser unnecessarily rejected it even though the original worker handles it.
epf = epf.replace("if (mod <= 0.0 || mod > 1.0)", "if (mod < 0.0 || mod > 1.0)")
command.write_text(text[:start] + epf + text[end:])

# Bridge desktop GUI geometry states that the command parser rejected: identity
# transforms, the GUI's full percentage range, and independent X/Y dimensions.
text = command.read_text()
start = text.index("int process_resample(")
end = text.index("int process_crop(", start)
resample = text[start:end]
resample = resample.replace("factor <= 0.2 || factor > 5.0", "factor < 0.01 || factor > 10.0")
resample = resample.replace("Should be between 0.2 and 5.0.", "Should be between 0.01 and 10.0.")
identity = '\t\tif (factor == 1.0) {\n\t\t\tsiril_log_message(_("Scale is 1.0. Not doing anything.\\n"));\n\t\t\treturn CMD_ARG_ERROR;\n\t\t}\n'
assert resample.count(identity) == 1
resample = resample.replace(identity, "")
branch = '\t\t} else if (!strcmp(word[i], "-noclamp")) {'
assert resample.count(branch) == 1
resample = resample.replace(branch, '\t\t} else if (g_str_has_prefix(word[i], "-height=")) {\n\t\t\ttoY = g_ascii_strtoull(word[i] + 8, &end, 10);\n\t\t\tif (end == word[i] + 8 || *end) return CMD_ARG_ERROR;\n' + branch)
guard = '\timage_cfa_warning_check();\n\tgui_iface.set_busy(TRUE);'
assert resample.count(guard) == 1
resample = resample.replace(guard, '''\tif (toX < 1 || toY < 1) return CMD_ARG_ERROR;
\tif (toX == gfit->rx && toY == gfit->ry) return CMD_OK;
#ifdef OS_IOS
\t/* Include output/copy/clamping buffers before allocating a large Mat. */
\tdouble required = (double)toX * toY * (gfit->naxes[2] * sizeof(float) + 4) * (clamp ? 5 : 3);
\tif (required > (double)get_available_memory() * 0.8) {
\t\tsiril_log_error("Not enough iPad processing memory for these output dimensions\\n");
\t\treturn CMD_ALLOC_ERROR;
\t}
#endif
''' + guard)
text = text[:start] + resample + text[end:]
start = text.index("int process_rotate(")
end = text.index("int process_rotatepi(", start)
rotation = text[start:end]
identity = '\t\tsiril_log_message(_("Angle is 0.0 or 360.0 degrees. Doing nothing...\\n"));\n\t\treturn CMD_ARG_ERROR;'
assert rotation.count(identity) == 1
rotation = rotation.replace(identity, '\t\tgui_iface.set_busy(FALSE);\n\t\treturn CMD_OK;')
command.write_text(text[:start] + rotation + text[end:])

# A script findstar normally frees its single-image results after reporting.
# The native star-mask workflow needs that selected-channel result, just as the
# desktop GUI does. Use the original locked ownership helpers; private/sequence
# callers keep their existing lifetime.
finder = source / "src/algos/star_finder.c"
text = finder.read_text()
old = "\telse if (!args->update_GUI)\n\t\tfree_fitted_stars(stars);"
assert text.count(old) == 1
text = text.replace(old, "\telse if (!args->update_GUI) {\n\t\tif (com.headless && !args->im.from_seq) replace_com_stars(stars);\n\t\telse free_fitted_stars(stars);\n\t}")
# Do not let a missing selected-channel result silently trigger the star-mask
# worker's green-channel fallback or reuse a previous single-image star list.
start = text.index("gpointer findstar_worker(")
empty = "\t} else {\n\t\tgoto END;\n\t}"
worker = text[start:]
assert worker.count(empty) == 1
worker = worker.replace(empty, "\t} else {\n\t\tif (com.headless && !args->im.from_seq && !args->stars) {\n\t\t\treplace_com_stars(NULL);\n\t\t\tretval = 1;\n\t\t}\n\t\tgoto END;\n\t}")
finder.write_text(text[:start] + worker)
single = source / "src/io/single_image.c"
text = single.read_text()
text = '#include "algos/PSF.h"\n' + text
old = "\tif (!com.headless)\n\t\tgui_iface.on_image_closed();"
assert text.count(old) == 1
single.write_text(text.replace(old, old + "\n\telse\n\t\treplace_com_stars(NULL);"))

formats = source / "src/io/image_formats_libraries.c"
text = formats.read_text()
start = text.index("int readjpg(")
end = text.index("int savejpg(", start)
reader = text[start:end]
reader = reader.replace("struct jpeg_decompress_struct cinfo;", "struct jpeg_decompress_struct cinfo = {0};")
reader = reader.replace("struct jpeg_error_mgr jerr;", "struct ipad_jpeg_error jerr = {0};")
reader = reader.replace("cinfo.err = jpeg_std_error(&jerr);", "cinfo.err = jpeg_std_error(&jerr.manager);\n\tjerr.manager.error_exit = ipad_jpeg_error_exit;\n\tif (setjmp(jerr.recovery)) {\n\t\tjpeg_destroy_decompress(&cinfo); fclose(f); free(jerr.pixels);\n\t\treturn OPEN_IMAGE_ERROR;\n\t}")
reader = reader.replace("WORD *data = malloc(npixels * sizeof(WORD) * 3);", "WORD *data = malloc(npixels * sizeof(WORD) * 3);\n\tjerr.pixels = data;")
# The original allocation has exactly three planes. Four-component CMYK must
# fail before allocation instead of exposing a fourth plane outside the buffer.
old_start = "\tjpeg_start_decompress(&cinfo);"
assert reader.count(old_start) == 1
reader = reader.replace(old_start, old_start + "\n\tif (cinfo.output_components != 1 && cinfo.output_components != 3) {\n\t\tsiril_log_error(\"Unsupported JPEG component layout\\n\");\n\t\tjpeg_destroy_decompress(&cinfo); fclose(f);\n\t\treturn OPEN_IMAGE_ERROR;\n\t}")
# libjpeg can still consume source bytes during finish. Keep FILE alive until
# then so the error handler can safely close it exactly once on late failures.
old_finish = "\tfclose(f);\n\tjpeg_finish_decompress(&cinfo);\n\tjpeg_destroy_decompress(&cinfo);"
assert reader.count(old_finish) == 1
reader = reader.replace(old_finish, "\tjpeg_finish_decompress(&cinfo);\n\tjpeg_destroy_decompress(&cinfo);\n\tfclose(f);")
reader = reader.replace("\t\tPRINT_ALLOC_ERR;\n\t\tfclose(f);", "\t\tPRINT_ALLOC_ERR;\n\t\tjpeg_destroy_decompress(&cinfo);\n\t\tfclose(f);")
helper = """struct ipad_jpeg_error {
    struct jpeg_error_mgr manager;
    jmp_buf recovery;
    void *volatile pixels;
};
static void ipad_jpeg_error_exit(j_common_ptr decoder) {
    struct ipad_jpeg_error *error = (struct ipad_jpeg_error *)decoder->err;
    char text[JMSG_LENGTH_MAX];
    decoder->err->format_message(decoder, text);
    siril_log_error("JPEG decode failed: %s\\n", text);
    longjmp(error->recovery, 1);
}
"""
formats.write_text(text[:start] + helper + reader + text[end:])

# Keep the original FFTW kernels. Zero-amplitude spectra have zero modulus
# and a neutral phase; avoid 0/0 while retaining the actual DFTNORM=0.
fft = source / "src/filters/fft.c"
text = fft.read_text()
assert text.count("(modul[i] / maxi)") == 1
text = text.replace("(modul[i] / maxi)", "(maxi > 0.f ? modul[i] / maxi : 0.f)")
assert text.count("(modul[i] * USHRT_MAX_SINGLE / maxi)") == 1
text = text.replace("(modul[i] * USHRT_MAX_SINGLE / maxi)", "(maxi > 0.f ? modul[i] * USHRT_MAX_SINGLE / maxi : 0.f)")
# CP_COPYA copies pixels, not DFT keywords. The desktop helper accidentally
# overwrites ord twice and writes global gfit even when given an owned image.
start = text.index("static void save_dft_information_in_gfit(")
end = text.index("static void FFTD_ushort", start)
text = text[:start] + '''static void save_dft_information(fits *source, fits *target) {
    strcpy(target->keywords.dft.type, source->keywords.dft.type);
    strcpy(target->keywords.dft.ord, source->keywords.dft.ord);
    for (int i = 0; i < source->naxes[2]; i++)
        target->keywords.dft.norm[i] = source->keywords.dft.norm[i];
}

''' + text[end:]
assert text.count("save_dft_information_in_gfit(tmp1);") == 1
text = text.replace("save_dft_information_in_gfit(tmp1);", "save_dft_information(tmp1, fit);")
# Inverse output is spatial, not a spectrum. Original CP_FORMAT doesn't clear
# inherited DFT metadata from the opened magnitude image.
needle = "\t\t/* Copy inverse transform result into fit for display */"
assert text.count(needle) == 1
text = text.replace(needle, "\t\tmemset(&fit->keywords.dft, 0, sizeof(fit->keywords.dft));\n" + needle)
fft.write_text(text)

# RGB PSF data already includes kernelchannels in ndata. The desktop helper
# multiplies it again, reading outside the original kernel when saving RGB.
deconv = source / "src/filters/deconvolution.c"
text = deconv.read_text()
assert text.count("ndata * com.kernelchannels * sizeof(float)") == 2
text = text.replace("ndata * com.kernelchannels * sizeof(float)", "ndata * sizeof(float)")
# Propagate original algorithm failures rather than reporting unchanged pixels
# as a successful operation (e.g. RL on an empty/black channel).
for name in ("split_bregman", "naive_richardson_lucy", "fft_richardson_lucy", "wienerdec"):
    needle = name + "(args->fdata,"
    assert text.count(needle) == 1
    text = text.replace(needle, "retval = " + needle)
needle = "\t\tgettimeofday(&t_end, NULL);\n\t\tif (sequence_is_running == 0)"
assert text.count(needle) == 1
text = text.replace(needle, "\t\tif (retval) goto ENDDECONV;\n" + needle)
# PSF estimation must also propagate get_kernel/save_kernel failures.
start = text.index("gpointer estimate_only(gpointer p)")
end = text.index("gpointer deconvolve(gpointer p)", start)
body = text[start:end]
assert body.count("\tget_kernel(args);") == 1
body = body.replace("\tget_kernel(args);", "\tretval = get_kernel(args);\n\tif (retval) goto ENDEST;")
body = body.replace("\t\tsave_kernel(args->savepsf_filename, args);", "\t\tretval = save_kernel(args->savepsf_filename, args);")
text = text[:start] + body + text[end:]
# Kernel samples are in pixel coordinates. Angular FWHM is for presentation,
# not for generating a pixel PSF: adding focal-length metadata must not change it.
needle = "\t\tdouble fwhmx, fwhmy;\n\t\tchar *unit;\n\t\tget_fwhm_as_arcsec_if_possible(com.stars[i], &fwhmx, &fwhmy, &unit);"
# Pinned source uses one more tab inside its while loop.
needle = needle.replace("\t\t", "\t\t\t")
assert text.count(needle) == 1
text = text.replace(needle, "\t\t\tdouble fwhmx = com.stars[i]->fwhmx, fwhmy = com.stars[i]->fwhmy;")
deconv.write_text(text)

# Spectral irregularity originally assumes a 150px patch even for smaller
# valid images. Preserve 150px for large inputs and bound small-image sampling.
gf = source / "src/filters/deconvolution/gf_estimate.cpp"
text = gf.read_text()
needle = "    assert(blurredImage.d == 1);"
assert text.count(needle) == 1
text = text.replace(needle, needle + "\n    windowSize = std::min(windowSize, std::min(static_cast<int>(blurredImage.w), static_cast<int>(blurredImage.h)));\n")
gf.write_text(text)

# The original light-curve engine leaks its SNR scratch buffer and can enter
# GSL/plot operations with zero simultaneous valid target/reference frames.
# Preserve its reference selection and math; reject the empty dataset before
# allocations/plotting and release the same scratch buffers on every path.
photometry = source / "src/algos/photometry.c"
text = photometry.read_text()
start = text.index("int new_light_curve(")
end = text.index("static gboolean end_light_curve_worker", start)
body = text[start:end]
needle = "\tint nb_valid_images = j;"
assert body.count(needle) == 1
body = body.replace(needle, needle + "\n\tif (!nb_valid_images) {\n\t\tfree(date); free(vmag); free(err); free(snr_opt);\n\t\tfree_siril_plot_data(spl_data);\n\t\treturn -1;\n\t}\n")
needle = "\tfree(err);\n\treturn ret;"
assert body.count(needle) == 1
body = body.replace(needle, "\tfree(err);\n\tfree(snr_opt);\n\treturn ret;")
photometry.write_text(text[:start] + body + text[end:])

# Auto-placement is called directly by the native AP editor, outside the
# original GUI worker. Keep C++ allocation/OpenCV failures behind the C ABI.
mpp = source / "src/registration/mpp.cpp"
with mpp.open("a") as output:
    output.write('''
extern "C" mpp_status_t embedded_mpp_ap_replace(mpp_run_t *run) {
    try { return mpp_ap_replace(run, run->cfg); }
    catch (const std::exception &e) {
        siril_log_message("AP placement failed: %s\\n", e.what());
        return MPP_ENOMEM;
    }
}
''')

# AP editor coordinates index the cropped mean reference, rather than the
# uncropped source frames. Keep the original box construction and clamp it
# against that same image, including the no-size-change resize fast path.
text = mpp.read_text()
start = text.index('extern "C" mpp_status_t mpp_ap_add(')
end = text.index('extern "C" mpp_status_t mpp_ap_resize(', start)
body = text[start:end]
needle = "run->frame_rows, run->frame_cols"
assert body.count(needle) == 2
body = body.replace(needle, "run->mean_frame_rows, run->mean_frame_cols")
mpp.write_text(text[:start] + body + text[end:])

# Full SER frames are vertically flipped to FITS storage before return.
# Sequence apply/save workers also need the true buffer orientation.
ser = source / "src/io/ser.c"
text = ser.read_text()
needle = '\tfits_flip_top_to_bottom(fit);\n\tfit->top_down = TRUE;\n\tsnprintf(fit->keywords.row_order, FLEN_VALUE, "TOP-DOWN");'
assert text.count(needle) == 1
text = text.replace(needle, needle.replace('= TRUE;', '= FALSE;').replace('"TOP-DOWN"', '"BOTTOM-UP"'))
ser.write_text(text)

# Raw SER reads flip rows after loading the stored mosaic. Analysis must use
# that in-memory Bayer orientation; the stack debayer runs before the flip.
text = mpp.read_text()
start = text.index("/* CFA SER → OpenCV")
end = text.index("\n}\n", start) + 3
body = text[start:end]
body = body.replace(" * the same pattern to librtprocess without orientation adjustment, and\n * ser_read_frame doesn't flip rows — so it maps directly. */",
    " * the same pattern to librtprocess before flipping rows. Raw analysis\n * reads have already been flipped and need the matching Bayer orientation. */")
assert "doesn't flip rows" not in body
needle = "\tswitch (seq->ser_file->color_id) {"
assert body.count(needle) == 1
body = body.replace(needle, "\tsensor_pattern pat;\n" + needle)
for pattern in ("RGGB", "BGGR", "GBRG", "GRBG"):
    needle = "return bayer_pattern_to_cv_code(BAYER_FILTER_" + pattern + ");"
    assert body.count(needle) == 1
    body = body.replace(needle, "pat = BAYER_FILTER_" + pattern + "; break;")
body = body.removesuffix("}\n") + "\tadjust_Bayer_pattern_orientation(&pat, seq->ser_file->image_height, TRUE);\n\treturn bayer_pattern_to_cv_code(pat);\n}\n"
mpp.write_text(text[:start] + body + text[end:])
