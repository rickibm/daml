-- Copyright (c) 2019 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0

-- Chat domain types. These should be derived automatically from the Daml model.

{-# LANGUAGE DuplicateRecordFields #-}

module Domain(Party(..),
              Introduce(..),
              Message(..),
              Broadcast(..),
             ) where

import DA.Ledger.Types as L (Party(..),Value(VList))
import DA.Ledger.Valuable (Valuable(..))
import Data.Text.Lazy (Text)

data Introduce = Introduce { from :: Party, people :: [Party] }
    deriving Show

instance Valuable Introduce where
    toValue Introduce{from,people} = L.VList [toValue from, toValue people]
    fromValue = \case
        L.VList [v1,v2] -> do
            from <- fromValue v1
            people <- fromValue v2
            return Introduce{from,people}
        _ -> Nothing

data Message = Message { from :: Party, to :: Party, body :: Text }
    deriving Show

instance Valuable Message where
    toValue Message{from,to,body} = L.VList [toValue from, toValue to, toValue body]
    fromValue = \case
        L.VList [v1,v2,v3] -> do
            from <- fromValue v1
            to <- fromValue v2
            body <- fromValue v3
            return Message{from,to,body}
        _ -> Nothing

data Broadcast = Broadcast { from :: Party, to :: [Party], body :: Text }
    deriving Show

instance Valuable Broadcast where
    toValue Broadcast{from,to,body} = L.VList [toValue from, toValue to, toValue body]
    fromValue = \case
        L.VList [v1,v2,v3] -> do
            from <- fromValue v1
            to <- fromValue v2
            body <- fromValue v3
            return Broadcast{from,to,body}
        _ -> Nothing
