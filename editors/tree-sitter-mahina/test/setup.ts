// Turns each test's `[REQ-n.m]` name tags into the JUnit `requirements`
// property (doc 79, tools/vitest-requirements.ts).
import { beforeEach } from "vitest";
import { citeRequirements } from "../../../tools/vitest-requirements";

beforeEach(citeRequirements);
