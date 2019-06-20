// Copyright (c) 2019 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

package com.digitalasset.lf_1_dev;


import com.daml.ledger.javaapi.data.DamlEnum;
import org.junit.jupiter.api.Test;
import org.junit.platform.runner.JUnitPlatform;
import org.junit.runner.RunWith;
import test.enum$.Color;

import static org.junit.jupiter.api.Assertions.*;

@RunWith(JUnitPlatform.class)
public class EnumTest {

    @Test
    void enum2Value2Enum() {
        for(Color c: new Color[]{Color.Red, Color.Green, Color.Blue})
            assertEquals(Color.fromValue(c.toValue()), c);
    }

    @Test
    void value2Enum2Enum() {
        for(String c: new String[]{"Red", "Green", "Blue"}) {
            assertEquals(Color.fromValue(new DamlEnum(c)).toValue().getConstructor(), c);
        }
    }

    @Test
    void badValue2Enum() {
        DamlEnum value = new DamlEnum("Yellow");
        assertThrows(IllegalArgumentException.class, () -> Color.fromValue(value));
    }
}
