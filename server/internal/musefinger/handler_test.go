package musefinger

import "testing"

func TestMusicXMLValidation(t *testing.T) {
	for _, value := range []string{
		`<?xml version="1.0"?><score-partwise version="4.0"><part-list/></score-partwise>`,
		`<score-partwise/>`,
	} {
		if !validMusicXML(value) {
			t.Fatalf("valid score rejected: %s", value)
		}
	}
	for _, value := range []string{"", `<html/>`, `<score-timewise/>`, `not xml`} {
		if validMusicXML(value) {
			t.Fatalf("invalid score accepted: %s", value)
		}
	}
}

func TestSources(t *testing.T) {
	for _, value := range []string{"import", "scan", "generated", "library"} {
		if !validSource(value) {
			t.Fatalf("source rejected: %s", value)
		}
	}
	if validSource("other") {
		t.Fatal("unknown source accepted")
	}
}
