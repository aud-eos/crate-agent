use crate::types::ListEntry;

/// Result of parsing a pasted list. `skipped` carries every line we
/// could not parse — surfaced loudly to the caller, never dropped.
#[derive(Debug, PartialEq, Eq)]
pub struct ParseResult {
    pub entries: Vec<ListEntry>,
    pub skipped: Vec<String>,
}

/// Parse a newline-delimited `Artist - Title` (or `Artist – Title`,
/// en-dash) list. Blank/whitespace-only lines are ignored. Lines with
/// no recognized separator go to `skipped`.
pub fn parse_text(input: &str) -> ParseResult {
    const SEPARATORS: [&str; 2] = [" - ", " – "]; // hyphen, en-dash

    let mut entries = Vec::new();
    let mut skipped = Vec::new();

    for raw_line in input.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }

        let split = SEPARATORS
            .iter()
            .filter_map(|separator| line.find(separator).map(|index| (index, separator.len())))
            .min_by_key(|(index, _)| *index);

        match split {
            Some((index, separator_len)) => {
                let artist = line[..index].trim().to_string();
                let title = line[index + separator_len..].trim().to_string();
                if artist.is_empty() || title.is_empty() {
                    skipped.push(line.to_string());
                } else {
                    entries.push(ListEntry {
                        artist,
                        title,
                        album: None,
                        year: None,
                        duration_secs: None,
                        isrc: None,
                        musicbrainz_recording_id: None,
                        format_preference: Default::default(),
                    });
                }
            }
            None => skipped.push(line.to_string()),
        }
    }

    ParseResult { entries, skipped }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(artist: &str, title: &str) -> ListEntry {
        ListEntry {
            artist: artist.to_string(),
            title: title.to_string(),
            album: None,
            year: None,
            duration_secs: None,
            isrc: None,
            musicbrainz_recording_id: None,
            format_preference: Default::default(),
        }
    }

    #[test]
    fn parses_hyphen_and_endash_separators() {
        let result = parse_text("Daft Punk - Around the World\nSigur Rós – Hoppípolla");
        assert_eq!(
            result.entries,
            vec![
                entry("Daft Punk", "Around the World"),
                entry("Sigur Rós", "Hoppípolla"),
            ]
        );
        assert!(result.skipped.is_empty());
    }

    #[test]
    fn trims_whitespace_and_ignores_blank_lines() {
        let result = parse_text("  Aphex Twin  -  Xtal  \n\n   \n");
        assert_eq!(result.entries, vec![entry("Aphex Twin", "Xtal")]);
        assert!(result.skipped.is_empty());
    }

    #[test]
    fn splits_on_first_separator_only() {
        let result = parse_text("Tyler, The Creator - See You Again - feat. Kali Uchis");
        assert_eq!(
            result.entries,
            vec![entry(
                "Tyler, The Creator",
                "See You Again - feat. Kali Uchis"
            ),]
        );
    }

    #[test]
    fn collects_unparseable_lines_into_skipped() {
        let result = parse_text("Just A Title With No Separator");
        assert!(result.entries.is_empty());
        assert_eq!(
            result.skipped,
            vec!["Just A Title With No Separator".to_string()]
        );
    }
}
