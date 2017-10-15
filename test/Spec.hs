import Test.Hspec
import Test.QuickCheck (property)

import Lib (sumUpMessages, RemoteMsg(Connect, Ping))

main :: IO ()
main = hspec $ do
  describe "Lib.sumUpMessages" $ do
    it "counts the elements" $ do
      property $ \numbers ->
        let msgs = Ping undefined undefined <$> numbers
        in fromInteger (fst (sumUpMessages msgs)) == length numbers

    it "computes the scalar product of the values" $ do
      let numbers = [0.8, 0.5, 0.1, 0.6]
          msgs = Ping undefined undefined <$> numbers
      snd (sumUpMessages msgs) `shouldBe` 4.5

    it "filters for only Pings" $ do
      let msgs = [Ping undefined undefined 0.5, Connect undefined]
      fst (sumUpMessages msgs) `shouldBe` 1
