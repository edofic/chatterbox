import           Test.Hspec
import           Test.QuickCheck (property)
import qualified Control.Distributed.Process as P
import qualified Data.Map as Map
import qualified Data.Set as Set

import Lib

main :: IO ()
main = hspec $ do
  describe "Lib.sumUpMessagesSuffix" $ do
    it "preserves input for empty suffix" $
      property $ \prefixCount prefixSum ->
        sumUpMessagesSuffix prefixCount prefixSum Set.empty == (prefixCount, prefixSum)

    it "counts the elements" $
      property $ \numbers ->
        let msgs = Set.fromList $ (\n -> (0, n)) `map` numbers
        in fromIntegral (fst (sumUpMessagesSuffix 0 0 msgs)) == length numbers

    it "computes the scalar product of the values" $ do
      let msgs = Set.fromList [(2, 0.8), (5, 0.5), (0, 0.1), (1, 0.6)]
      snd (sumUpMessagesSuffix 0 0 msgs) `shouldBe` 5.7

  describe "Lib.compact" $ do
    it "does nothing for non-running" $ do
      let connecting = Connecting Set.empty
      compact connecting `shouldBe` connecting
      compact Quitted `shouldBe` Quitted

    it "does nothing when minimum timestamp is too soon" $ do
      let state = emptyRunning { received = Set.fromList [(1, 0.2), (2, 0.5)]
                               , latest = Map.fromList [(nodeId1, 0), (nodeId2, 3)]
                               }
      compact state `shouldBe` state

    it "compacts before the minimum timestamp" $ do
      let state = emptyRunning { received = Set.fromList [(6, 0.5), (8, 0.25), (10, 0.8)]
                               , latest = Map.fromList [(nodeId1, 9), (nodeId2, 10)]
                               , prefix = Prefix 5 7.2 5
                               }
          state' = state { received = Set.fromList [(10, 0.8)]
                         , latest = Map.fromList [(nodeId1, 9), (nodeId2, 10)]
                         , prefix = Prefix 7 11.95 5
                         }
      compact state `shouldBe` state'
      compact (compact state) `shouldBe` state'


emptyRunning :: AppState
emptyRunning = Running { msgStream = []
                       , buffer = Map.empty
                       , received = Set.empty
                       , latest = Map.empty
                       , prefix = Prefix 0 0 0
                       , sendingTimestamp = 0
                       , stopping = False
                       , acked = Set.empty
                       }


nodeId1, nodeId2 :: P.NodeId
nodeId1 = packPeer "nid1"
nodeId2 = packPeer "nid2"
