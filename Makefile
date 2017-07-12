all:
	@echo !!! This Makefile is for development purposes only. !!!
	@echo !!! Users should instead use Setup.hs or cabal. !!!
	@echo
	@echo Development targets: std prof lint clean
	@exit 1

WARNING_FLAGS=-W -Wall -fwarn-tabs -fwarn-incomplete-record-updates -fwarn-unused-do-bind -fno-warn-missing-signatures
GHC=ghc $(WARNING_FLAGS) -rtsopts 

std:
	$(GHC) --make HaskellPdfPresenter.hs

# Two stage profile build, due to Template Haskell not playing nice with profiling.
# See: http://www.haskell.org/ghc/docs/6.12.1/html/users_guide/template-haskell.html#id3029367
prof: std
	$(GHC) --make HaskellPdfPresenter.hs -prof -osuf p_o

lint:
	hlint HaskellPdfPresenter.hs

clean:
	rm -f HaskellPdfPresenter HaskellPdfPresenter.hi HaskellPdfPresenter.hp HaskellPdfPresenter.o HaskellPdfPresenter.p_o
