README.html: README.rst
	rst2html $< > $@

clean:
	rm -f README.html

.DELETE_ON_ERROR:
