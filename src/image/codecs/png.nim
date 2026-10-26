## png codec — stub (full port pending, see plans/0*.md).
## Returns Unsupported for now; Tier1/2/3 order: pnm/tga/hdr/bmp -> png/gif/tiff/ico -> jpeg/webp/exr/avif.
import ../error
import ../decoder
import ../io
import ../color

proc decodeStub*(name: string): ImageResult[bool] =
  err[bool](unsupportedError(ukGenericFeature, name & ": not yet implemented"))

proc prepareStub*(name: string): ImageResult[DecoderPreparedImage] =
  err[DecoderPreparedImage](unsupportedError(ukGenericFeature, name & ": not yet implemented"))
