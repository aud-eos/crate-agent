use crate::types::ListEntry;

/// Build a Soulseek search string from a list entry. slskd matches the
/// space-separated terms against shared filenames, so we reduce artist
/// and title to lowercased alphanumeric tokens (punctuation that would
/// fragment matches is dropped) and join them with single spaces.
pub fn build_query(entry: &ListEntry) -> String {
    fn tokenize(text: &str) -> String {
        text.chars()
            .map(|character| {
                if character.is_alphanumeric() {
                    character
                } else {
                    ' '
                }
            })
            .collect::<String>()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .to_lowercase()
    }

    let combined = format!("{} {}", tokenize(&entry.artist), tokenize(&entry.title));
    combined.split_whitespace().collect::<Vec<_>>().join(" ")
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
    fn lowercases_and_joins_artist_and_title() {
        assert_eq!(
            build_query(&entry("Daft Punk", "Around the World")),
            "daft punk around the world"
        );
    }

    #[test]
    fn strips_punctuation_that_fragments_matching() {
        assert_eq!(
            build_query(&entry(
                "Tyler, The Creator",
                "See You Again (feat. Kali Uchis)"
            )),
            "tyler the creator see you again feat kali uchis"
        );
    }

    #[test]
    fn preserves_unicode_letters_and_digits() {
        assert_eq!(
            build_query(&entry("Sigur Rós", "Festival 2")),
            "sigur rós festival 2"
        );
    }

    #[test]
    fn collapses_repeated_whitespace() {
        assert_eq!(build_query(&entry("A   B", "C  -  D")), "a b c d");
    }
}
