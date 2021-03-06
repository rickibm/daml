// Copyright (c) 2019 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package com.digitalasset.daml.lf.testing.archive

import java.io.File

import com.digitalasset.daml.bazeltools.BazelRunfiles
import com.digitalasset.daml.lf.archive.UniversalArchiveReader
import org.scalatest.{Matchers, WordSpec}

class DamlLfAssemblerTest extends WordSpec with Matchers with BazelRunfiles {

  "dalf generated by damllf-as" should {

    "be readable" in {

      UniversalArchiveReader().readFile(new File(rlocation("daml-lf/encoder/Test.dalf"))) shouldBe 'success

    }

  }

}
