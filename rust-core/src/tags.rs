// Audio file tag I/O via `lofty`.
//
// SP-1 uses this for *reading* tags only — the filename template engine
// needs $artist / $title / $mixtype etc. populated. Tag writing is added
// in SP-1.5 (library hygiene) and used heavily by SP-2 (MusicBrainz
// auto-tagger) and Pillar F (re-encoding metadata propagation).
//
// Implementations land alongside the SP-1 fingerprinting pipeline (same
// pass over each file).
